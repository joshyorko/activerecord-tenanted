# frozen_string_literal: true

require "test_helper"

describe "PostgreSQL database tasks on a fresh server" do
  {
    database: "postgresql/primary_db_database_strategy",
    schema: "postgresql/primary_db_schema_strategy",
  }.each do |strategy, scenario|
    with_scenario(scenario, :primary_record) do
      test "#{strategy} create, prepare, migrate, and drop converge on a ready tenant" do
        Rails.application.config.active_record_tenanted.connection_class = "TenantedApplicationRecord"
        tasks = ActiveRecord::Tenanted::DatabaseTasks.new(base_config)
        tenant_config = base_config.new_tenant_config("task_fresh")

        tasks.drop_all
        assert_not_predicate(tenant_config.config_adapter, :database_exist?) unless strategy == :schema

        tasks.create_all
        assert base_database_exists?(base_config.database) if strategy == :schema
        assert_not_predicate(tenant_config.config_adapter, :database_exist?)

        with_artenant("task_fresh") { tasks.migrate_tenant }
        assert_predicate(tenant_config.config_adapter, :database_exist?)
        assert_equal(20250203191115, migration_version(tenant_config))

        with_new_migration_file
        with_artenant("task_fresh") { tasks.migrate_tenant }
        assert_equal(20250213005959, migration_version(tenant_config))

        tasks.drop_tenant("task_fresh")
        assert_not_predicate(tenant_config.config_adapter, :database_exist?)
      end

      test "#{strategy} prepare recovers an existing resource with incomplete migrations" do
        tasks = ActiveRecord::Tenanted::DatabaseTasks.new(base_config)
        tenant_config = base_config.new_tenant_config("task_recovery")

        tasks.migrate_tenant("task_recovery")
        assert_equal(20250203191115, migration_version(tenant_config))

        with_new_migration_file
        tasks.migrate_tenant("task_recovery")

        assert_equal(20250213005959, migration_version(tenant_config))
      end

      test "#{strategy} drop waits for the tenant lifecycle lock" do
        tasks = ActiveRecord::Tenanted::DatabaseTasks.new(base_config)
        tenant_config = base_config.new_tenant_config("task_drop")
        tasks.migrate_tenant("task_drop")

        lock_entered = Queue.new
        release_lock = Queue.new
        drop_started = Queue.new
        drop_completed = Queue.new

        holder = Thread.new do
          ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock.new(base_config).synchronize("task_drop") do
            lock_entered << true
            release_lock.pop
          end
        end
        lock_entered.pop

        dropper = Thread.new do
          drop_started << true
          ActiveRecord::Tenanted::DatabaseTasks.new(base_config).drop_tenant("task_drop")
          drop_completed << true
        end
        drop_started.pop

        assert_nil(drop_completed.pop(timeout: 0.2), "drop must wait while another lifecycle owns the tenant lock")
        assert_predicate(self, :advisory_lock_waiter_appears?, "drop should wait on PostgreSQL's advisory lock")
        assert_predicate(tenant_config.config_adapter, :database_exist?)

        release_lock << true
        assert(drop_completed.pop(timeout: 5), "drop should complete after the lifecycle lock is released")
        assert_not_predicate(tenant_config.config_adapter, :database_exist?)
      ensure
        release_lock << true if holder&.alive?
        holder&.join
        dropper&.join
      end

      test "#{strategy} migrate_all prepares the configured local default on a fresh server" do
        tasks = ActiveRecord::Tenanted::DatabaseTasks.new(base_config)
        Rails.application.config.active_record_tenanted.default_tenant = "task_default"
        tenant_config = base_config.new_tenant_config("task_default")

        tasks.drop_all
        tasks.create_all
        with_artenant(nil) { tasks.migrate_all }

        assert_predicate(tenant_config.config_adapter, :database_exist?)
        assert_equal(20250203191115, migration_version(tenant_config))
      end
    end
  end

  with_scenario("postgresql/primary_db_schema_strategy", :primary_record) do
    test "schema create waits for the colocated storage lifecycle lock" do
      tasks = ActiveRecord::Tenanted::DatabaseTasks.new(base_config)
      tasks.drop_all

      lock_entered = Queue.new
      release_lock = Queue.new
      create_started = Queue.new
      create_completed = Queue.new

      holder = Thread.new do
        ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::AdvisoryLock.new(base_config).synchronize("\0colocated") do
          lock_entered << true
          release_lock.pop
        end
      end
      lock_entered.pop

      creator = Thread.new do
        create_started << true
        ActiveRecord::Tenanted::DatabaseTasks.new(base_config).create_all
        create_completed << true
      end
      create_started.pop

      assert_nil(create_completed.pop(timeout: 0.2), "create must wait while another lifecycle owns the storage lock")
      assert_predicate(self, :advisory_lock_waiter_appears?, "create should wait on PostgreSQL's advisory lock")
      assert_not(base_database_exists?(base_config.database))

      release_lock << true
      assert(create_completed.pop(timeout: 5), "create should complete after the storage lock is released")
      assert(base_database_exists?(base_config.database))
    ensure
      release_lock << true if holder&.alive?
      holder&.join
      creator&.join
    end
  end

  def with_artenant(tenant)
    previous = ENV["ARTENANT"]
    ENV["ARTENANT"] = tenant
    yield
  ensure
    ENV["ARTENANT"] = previous
  end

  def migration_version(config)
    ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |connection|
      return connection.pool.migration_context.current_version
    end
  end

  def base_database_exists?(database)
    root_config = TenantedApplicationRecord.tenanted_root_config
    maintenance_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      root_config.env_name,
      "_task_test_maintenance",
      root_config.configuration_hash.except(:tenanted, :schema_name_pattern).merge(
        database: root_config.configuration_hash[:maintenance_database] || "postgres",
        database_tasks: false
      )
    )

    ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(maintenance_config) do |connection|
      connection.select_value(
        "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = #{connection.quote(database)})"
      )
    end
  end

  def advisory_lock_waiter_appears?
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2

    loop do
      waiting = with_maintenance_connection do |connection|
        connection.select_value(<<~SQL).to_i.positive?
          SELECT COUNT(*)
          FROM pg_stat_activity
          WHERE wait_event_type = 'Lock' AND wait_event = 'advisory'
        SQL
      end
      return true if waiting
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def with_maintenance_connection(&block)
    root_config = TenantedApplicationRecord.tenanted_root_config
    maintenance_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      root_config.env_name,
      "_task_test_maintenance",
      root_config.configuration_hash.except(:tenanted, :schema_name_pattern).merge(
        database: root_config.configuration_hash[:maintenance_database] || "postgres",
        database_tasks: false
      )
    )

    ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(maintenance_config, &block)
  end
end
