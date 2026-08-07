# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Factory do
  describe "strategy selection" do
    test "returns Database adapter when database name contains %{tenant}" do
      config_hash = { adapter: "postgresql", database: "test_%{tenant}" }
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", config_hash)

      adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Factory.new(db_config)

      assert_instance_of ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Database, adapter
    end

    test "returns Schema adapter for a static database with a schema template" do
      config_hash = {
        adapter: "postgresql",
        database: "myapp_production",
        schema_name_pattern: "tenant_%{tenant}",
      }
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", config_hash)

      adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Factory.new(db_config)

      assert_instance_of ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Schema, adapter
    end

    test "rejects an ambiguous configuration with two tenant templates" do
      config_hash = {
        adapter: "postgresql",
        database: "myapp_%{tenant}",
        schema_name_pattern: "tenant_%{tenant}",
      }
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", config_hash)

      error = assert_raises(ActiveRecord::Tenanted::ConfigurationError) do
        ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Factory.new(db_config)
      end

      assert_match(/exactly one PostgreSQL tenant template/, error.message)
    end

    test "rejects a static database without a schema template" do
      config_hash = { adapter: "postgresql", database: "myapp_production" }
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", config_hash)

      error = assert_raises(ActiveRecord::Tenanted::ConfigurationError) do
        ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Factory.new(db_config)
      end

      assert_match(/schema_name_pattern/, error.message)
    end

    test "returns Database adapter with just %{tenant} as database name" do
      config_hash = {
        adapter: "postgresql",
        database: "%{tenant}",
      }
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", config_hash)

      adapter = ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Factory.new(db_config)

      assert_instance_of ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL::Database, adapter
    end
  end
end
