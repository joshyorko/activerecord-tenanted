# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock do
  let(:config) do
    ActiveRecord::Tenanted::DatabaseConfigurations::BaseConfig.new(
      "test",
      "primary",
      adapter: "postgresql",
      tenanted: true,
      database: "advisory_lock_%{tenant}",
      host: ENV.fetch("POSTGRES_HOST", "127.0.0.1"),
      port: ENV.fetch("POSTGRES_PORT", "5432"),
      username: ENV.fetch("POSTGRES_USERNAME", "postgres"),
      password: ENV.fetch("POSTGRES_PASSWORD", "postgres"),
      maintenance_database: ENV.fetch("POSTGRES_MAINTENANCE_DATABASE", "postgres")
    )
  end

  test "derives a deterministic signed 64-bit key from the lifecycle identity" do
    key = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock.new(config)
      .send(:lock_key, "retailer-one")
    same_key = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock.new(config)
      .send(:lock_key, "retailer-one")
    other_tenant_key = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock.new(config)
      .send(:lock_key, "retailer-two")

    assert_includes(-(2**63)...(2**63), key)
    assert_equal(key, same_key)
    assert_not_equal(key, other_tenant_key)
  end

  test "serializes the same tenant across two maintenance connections" do
    first_entered = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    second_entered = Queue.new

    first = Thread.new do
      ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock.new(config).synchronize("retailer-one") do
        first_entered << true
        release_first.pop
      end
    end
    first_entered.pop

    second = Thread.new do
      second_started << true
      ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock.new(config).synchronize("retailer-one") do
        second_entered << true
      end
    end
    second_started.pop

    assert_nil(second_entered.pop(timeout: 0.2), "second lifecycle must remain blocked while the first holds the lock")
    release_first << true
    assert(second_entered.pop(timeout: 2), "second lifecycle should enter after the first releases the lock")
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end

  test "releases the session lock when the lifecycle raises" do
    lock = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock.new(config)

    assert_raises(RuntimeError) do
      lock.synchronize("retailer-one") { raise "interrupted" }
    end

    entered = false
    lock.synchronize("retailer-one") { entered = true }
    assert entered
  end
end
