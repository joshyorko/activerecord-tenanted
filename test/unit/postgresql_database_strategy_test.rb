# frozen_string_literal: true

require "test_helper"

describe "PostgreSQL database-per-tenant strategy" do
  with_scenario("postgresql/primary_db_database_strategy", :primary_record) do
    test "creates isolated tenant databases and persists tenant data" do
      TenantedApplicationRecord.create_tenant("retailer-one")
      TenantedApplicationRecord.create_tenant("retailer-two")

      TenantedApplicationRecord.with_tenant("retailer-one") do
        User.create!(email: "owner@one.example")
        assert_equal([ "owner@one.example" ], User.pluck(:email))
        assert_equal "test_retailer-one", User.connection_db_config.database
      end

      TenantedApplicationRecord.with_tenant("retailer-two") do
        assert_empty User.all
        User.create!(email: "owner@two.example")
        assert_equal([ "owner@two.example" ], User.pluck(:email))
        assert_equal "test_retailer-two", User.connection_db_config.database
      end
    end
  end
end
