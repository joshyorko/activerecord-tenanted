# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::NameTemplate do
  let(:template_class) { ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::NameTemplate }
  let(:template) { template_class.new("tenant_%{tenant}", label: "schema_name_pattern") }

  test "maps logical tenant names to reversible physical identifiers" do
    [ "retailer-one", "550e8400-e29b-41d4-a716-446655440000", 12345 ].each do |tenant|
      physical = template.physical_name(tenant)

      assert_equal tenant.to_s, template.logical_name(physical)
    end
  end

  test "does not match names outside its namespace" do
    assert_nil template.logical_name("public")
    assert_nil template.logical_name("unrelated_retailer-one")
  end

  test "requires exactly one tenant placeholder" do
    [ "tenant", "%{tenant}_%{tenant}" ].each do |pattern|
      error = assert_raises(ActiveRecord::Tenanted::ConfigurationError) do
        template_class.new(pattern, label: "schema_name_pattern")
      end

      assert_match(/exactly one %\{tenant\} placeholder/, error.message)
    end
  end

  test "rejects empty tenant names" do
    assert_raises(ActiveRecord::Tenanted::BadTenantNameError) do
      template.physical_name("")
    end
  end

  test "enforces PostgreSQL's 63-byte identifier limit" do
    error = assert_raises(ActiveRecord::Tenanted::BadTenantNameError) do
      template.physical_name("é" * 29)
    end

    assert_match(/63 bytes/, error.message)
  end

  test "rejects NUL without rejecting quoted PostgreSQL identifier characters" do
    assert_equal "tenant_north america.v2", template.physical_name("north america.v2")

    assert_raises(ActiveRecord::Tenanted::BadTenantNameError) do
      template.physical_name("bad\0tenant")
    end
  end

  test "maps parallel workers reversibly without mangling suffix-looking tenants" do
    worker_one = template.physical_name("retailer_1", worker_id: 1)
    worker_two = template.physical_name("retailer_1", worker_id: 2)

    assert_not_equal worker_one, worker_two
    assert_equal "retailer_1", template.logical_name(worker_one, worker_id: 1)
    assert_equal "retailer_1", template.logical_name(worker_two, worker_id: 2)
    assert_nil template.logical_name(worker_one, worker_id: 2)
  end

  test "includes the worker namespace in the identifier byte limit" do
    assert_raises(ActiveRecord::Tenanted::BadTenantNameError) do
      template.physical_name("a" * 50, worker_id: 1)
    end
  end
end
