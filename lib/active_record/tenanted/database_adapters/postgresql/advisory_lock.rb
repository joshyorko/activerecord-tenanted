# frozen_string_literal: true

require "digest"

module ActiveRecord
  module Tenanted
    module DatabaseAdapters
      module PostgreSQL
        class AdvisoryLock
          def initialize(db_config)
            @db_config = db_config
          end

          def synchronize(tenant)
            key = lock_key(tenant)
            connection = maintenance_config.new_connection

            locked = false
            begin
              connection.execute("SELECT pg_advisory_lock(#{key})")
              locked = true
              yield
            ensure
              connection.execute("SELECT pg_advisory_unlock(#{key})") if locked
              connection.disconnect!
            end
          end

        private
          attr_reader :db_config

          def lock_key(tenant)
            identity = [
              "active_record_tenanted",
              db_config.env_name,
              db_config.name,
              strategy,
              resource_template,
              db_config.respond_to?(:test_worker_id) ? db_config.test_worker_id : nil,
              tenant.to_s,
            ].join("\0")

            Digest::SHA256.digest(identity).unpack1("q>")
          end

          def strategy
            db_config.configuration_hash[:schema_name_pattern].present? ? "schema" : "database"
          end

          def resource_template
            db_config.configuration_hash[:schema_name_pattern] || db_config.database
          end

          def maintenance_config
            configuration_hash = db_config.configuration_hash.except(
              :schema_name_pattern,
              :schema_search_path,
              :tenant,
              :tenant_database,
              :tenant_schema,
              :tenanted,
              :tenanted_adapter_class,
              :tenanted_config_name
            ).merge(
              database: db_config.configuration_hash[:maintenance_database] || "postgres",
              database_tasks: false
            )

            ActiveRecord::DatabaseConfigurations::HashConfig.new(
              db_config.env_name,
              "_tenanted_maintenance_#{db_config.name}",
              configuration_hash
            )
          end
        end
      end
    end
  end
end
