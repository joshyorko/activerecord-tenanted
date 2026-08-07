# frozen_string_literal: true

require "test_helper"
require "active_record/connection_adapters/postgresql_adapter"

describe "PostgreSQL Rails API isolation" do
  test "leaves create_schema owned by Rails with its duplicate and force keywords" do
    adapter_class = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter

    assert_not adapter_class.ancestors.any? {
      _1.name == "ActiveRecord::Tenanted::Patches::PostgreSQLSchemaStatements"
    }

    parameters = adapter_class.instance_method(:create_schema).parameters
    assert_includes parameters, [ :key, :force ]
    assert_includes parameters, [ :key, :if_not_exists ]
  end

  test "leaves schema_search_path assignment owned by Rails" do
    method = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.instance_method(:schema_search_path=)

    assert_equal ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaStatements, method.owner
    assert_equal [ [ :req, :schema_csv ] ], method.parameters
  end
end
