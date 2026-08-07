# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema do
  let(:db_config) do
    config_hash = { adapter: "postgresql", database: "myapp", schema_name_pattern: "tenant_%{tenant}" }
    ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", config_hash)
  end
  let(:adapter) { ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config) }

  describe "database_path" do
    test "returns tenant_schema from config if present" do
      db_config_with_schema = Object.new
      def db_config_with_schema.database; "myapp_%{tenant}"; end
      def db_config_with_schema.configuration_hash
        { tenant_schema: "myapp_foo" }
      end

      adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config_with_schema)
      assert_equal "myapp_foo", adapter.database_path
    end

    test "raises error if tenant_schema not present" do
      db_config_dynamic = Object.new
      def db_config_dynamic.database; "myapp_development"; end
      def db_config_dynamic.configuration_hash; {}; end

      adapter_dynamic = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config_dynamic)

      error = assert_raises(ActiveRecord::Tenanted::NoTenantError) do
        adapter_dynamic.database_path
      end

      assert_match(/tenant_schema not set/, error.message)
    end
  end

  describe "prepare_tenant_config_hash" do
    test "adds schema-specific configuration using the tenant name" do
      base_config = Object.new
      def base_config.database; "myapp_development"; end
      def base_config.configuration_hash; { schema_name_pattern: "tenant_%{tenant}" }; end

      config_hash = { tenant: "foo", database: "myapp_development" }
      result = adapter.prepare_tenant_config_hash(config_hash, base_config, "foo")

      assert_equal "tenant_foo", result[:schema_search_path]
      assert_equal "tenant_foo", result[:tenant_schema]
      assert_equal "myapp_development", result[:database]
    end

    test "isolates the same suffix-looking tenant across parallel workers" do
      worker_one = Struct.new(:database, :configuration_hash, :test_worker_id)
        .new("myapp_development", { schema_name_pattern: "tenant_%{tenant}" }, 1)
      worker_two = Struct.new(:database, :configuration_hash, :test_worker_id)
        .new("myapp_development", { schema_name_pattern: "tenant_%{tenant}" }, 2)

      first = adapter.prepare_tenant_config_hash({}, worker_one, "retailer_1")
      second = adapter.prepare_tenant_config_hash({}, worker_two, "retailer_1")

      assert_not_equal first[:tenant_schema], second[:tenant_schema]
      assert_equal first[:tenant_schema], first[:schema_search_path]
      assert_equal second[:tenant_schema], second[:schema_search_path]
    end

    test "uses static database name" do
      base_config = Object.new
      def base_config.database; "rails_backend_production"; end
      def base_config.configuration_hash; { schema_name_pattern: "tenant_%{tenant}" }; end

      config_hash = { tenant: "bar" }
      result = adapter.prepare_tenant_config_hash(config_hash, base_config, "bar")

      assert_equal "tenant_bar", result[:schema_search_path]
      assert_equal "tenant_bar", result[:tenant_schema]
      # Database name should remain static
      assert_equal "rails_backend_production", result[:database]
    end

    test "creates schema name for complex tenant" do
      base_config = Object.new
      def base_config.database; "myapp_production"; end
      def base_config.configuration_hash; { schema_name_pattern: "tenant_%{tenant}" }; end

      config_hash = { tenant: "abc123" }
      result = adapter.prepare_tenant_config_hash(config_hash, base_config, "abc123")

      assert_equal "tenant_abc123", result[:schema_search_path]
      assert_equal "tenant_abc123", result[:tenant_schema]
      # Database name should remain static
      assert_equal "myapp_production", result[:database]
    end
  end

  describe "identifier_for" do
    test "returns the tenant name as the schema name" do
      db_config_static = Object.new
      def db_config_static.database; "myapp_development"; end
      def db_config_static.configuration_hash; { schema_name_pattern: "tenant_%{tenant}" }; end

      adapter_static = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config_static)
      result = adapter_static.identifier_for("foo")
      assert_equal "tenant_foo", result
    end

    test "uses complex tenant names unchanged" do
      db_config_static = Object.new
      def db_config_static.database; "myapp_development"; end
      def db_config_static.configuration_hash; { schema_name_pattern: "tenant_%{tenant}" }; end

      adapter_static = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config_static)
      result = adapter_static.identifier_for("abc123")
      assert_equal "tenant_abc123", result
    end
  end

  describe "tenant_databases" do
    test "returns only logical tenants in its configured namespace" do
      rows = [
        { "schema_name" => "information_schema" },
        { "schema_name" => "pg_catalog" },
        { "schema_name" => "public" },
        { "schema_name" => "unrelated" },
        { "schema_name" => "tenant_retailer-one" },
        { "schema_name" => "tenant_550e8400-e29b-41d4-a716-446655440000" },
      ]
      executed_sql = []
      connection = Object.new
      connection.define_singleton_method(:execute) { |sql| executed_sql << sql; rows }

      adapter.stub :with_base_connection, ->(&block) { block.call(connection) } do
        assert_equal [ "retailer-one", "550e8400-e29b-41d4-a716-446655440000" ], adapter.tenant_databases
      end
      assert_no_match(/\bLIKE\b/i, executed_sql.fetch(0))
    end

    test "enumerates only the configured worker and preserves suffix-looking tenants" do
      worker_config = Struct.new(:database, :configuration_hash, :test_worker_id)
        .new("myapp", { schema_name_pattern: "tenant_%{tenant}" }, 1)
      worker_adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(worker_config)
      rows = [
        { "schema_name" => "tenant_retailer_1~w1~la" },
        { "schema_name" => "tenant_retailer_1~w2~la" },
      ]
      connection = Object.new
      connection.define_singleton_method(:execute) { |_sql| rows }

      worker_adapter.stub :with_base_connection, ->(&block) { block.call(connection) } do
        assert_equal [ "retailer_1" ], worker_adapter.tenant_databases
      end
    end
  end

  describe "colocated?" do
    test "returns true for schema-based strategy" do
      assert_equal true, adapter.colocated?
    end
  end

  describe "create_database" do
    test "uses Rails native idempotent schema creation" do
      config_hash = {
        adapter: "postgresql",
        database: "myapp",
        schema_name_pattern: "tenant_%{tenant}",
        tenant_schema: "tenant_retailer-one",
        username: "app_user",
      }
      tenant_config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", config_hash)
      tenant_adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(tenant_config)
      calls = []
      connection = Object.new
      connection.define_singleton_method(:create_schema) { |name, **options| calls << [ name, options ] }
      connection.define_singleton_method(:quote_table_name) { |name| %Q("#{name}") }
      connection.define_singleton_method(:execute) { |_sql| }
      connection.define_singleton_method(:transaction_open?) { false }

      tenant_adapter.stub :with_base_connection, ->(&block) { block.call(connection) } do
        tenant_adapter.create_database
      end

      assert_equal [ [ "tenant_retailer-one", { if_not_exists: true } ] ], calls
    end
  end

  describe "create_colocated_database" do
    test "delegates to Rails DatabaseTasks.create with static database config" do
      # This test verifies that create_colocated_database fully integrates with Rails
      db_config_static = Object.new
      def db_config_static.database; "myapp_development"; end
      def db_config_static.configuration_hash; { adapter: "postgresql" }; end
      def db_config_static.env_name; "test"; end
      def db_config_static.name; "primary"; end

      adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config_static)
      base_db_name = "myapp_development"

      # Verify DatabaseTasks.create is called with the correct config
      ActiveRecord::Tasks::DatabaseTasks.stub :create, ->(config) do
        assert_equal base_db_name, config.database
        assert_equal "test", config.env_name
        assert_equal "postgresql", config.configuration_hash[:adapter]
      end do
        adapter.create_colocated_database
      end
    end

    test "uses static database name" do
      db_config_static = Object.new
      def db_config_static.database; "myapp_production"; end
      def db_config_static.configuration_hash
        { adapter: "postgresql" }
      end
      def db_config_static.env_name; "test"; end
      def db_config_static.name; "primary"; end

      adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config_static)

      # Verify DatabaseTasks.create is called with static database name
      ActiveRecord::Tasks::DatabaseTasks.stub :create, ->(config) do
        assert_equal "myapp_production", config.database
        assert_equal "test", config.env_name
        assert_equal "postgresql", config.configuration_hash[:adapter]
      end do
        adapter.create_colocated_database
      end
    end
  end

  describe "drop_colocated_database" do
    test "delegates to Rails DatabaseTasks.drop with static database config" do
      # This test verifies that drop_colocated_database fully integrates with Rails
      db_config_static = Object.new
      def db_config_static.database; "myapp_development"; end
      def db_config_static.configuration_hash; { adapter: "postgresql" }; end
      def db_config_static.env_name; "test"; end
      def db_config_static.name; "primary"; end

      adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config_static)
      base_db_name = "myapp_development"

      # Verify DatabaseTasks.drop is called with the correct config
      ActiveRecord::Tasks::DatabaseTasks.stub :drop, ->(config) do
        assert_equal base_db_name, config.database
        assert_equal "test", config.env_name
        assert_equal "postgresql", config.configuration_hash[:adapter]
      end do
        adapter.drop_colocated_database
      end
    end

    test "uses static database name" do
      db_config_static = Object.new
      def db_config_static.database; "myapp_production"; end
      def db_config_static.configuration_hash
        { adapter: "postgresql" }
      end
      def db_config_static.env_name; "test"; end
      def db_config_static.name; "primary"; end

      adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema.new(db_config_static)

      # Verify DatabaseTasks.drop is called with static database name
      ActiveRecord::Tasks::DatabaseTasks.stub :drop, ->(config) do
        assert_equal "myapp_production", config.database
        assert_equal "test", config.env_name
        assert_equal "postgresql", config.configuration_hash[:adapter]
      end do
        adapter.drop_colocated_database
      end
    end
  end
end
