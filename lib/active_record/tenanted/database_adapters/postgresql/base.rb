# frozen_string_literal: true

module ActiveRecord
  module Tenanted
    module DatabaseAdapters
      module PostgreSQL
        # Base class for PostgreSQL multi-tenancy strategies
        #
        # PostgreSQL supports two isolation strategies:
        # 1. Schema-based: Multiple schemas within a single database (default)
        # 2. Database-based: Separate databases per tenant
        #
        # This base class provides common functionality for both strategies.
        class Base
          attr_reader :db_config

          def initialize(db_config)
            @db_config = db_config
          end

          # Abstract methods - must be implemented by subclasses
          def tenant_databases
            raise NotImplementedError, "#{self.class.name} must implement #tenant_databases"
          end

          def create_database
            raise NotImplementedError, "#{self.class.name} must implement #create_database"
          end

          def drop_database
            raise NotImplementedError, "#{self.class.name} must implement #drop_database"
          end

          def database_exist?
            raise NotImplementedError, "#{self.class.name} must implement #database_exist?"
          end

          def database_path
            raise NotImplementedError, "#{self.class.name} must implement #database_path"
          end

          # Shared validation logic for PostgreSQL identifiers
          def validate_tenant_name(tenant_name)
            return if tenant_name == "%" || tenant_name == "(.+)"

            name_template.physical_name(tenant_name)
          end

          # Returns the identifier (database or schema name) for validation
          # Subclasses can override if needed
          def identifier_for(tenant_name)
            name_template.physical_name(tenant_name)
          end

          def database_ready?
            database_exist?
          end

          def acquire_ready_lock(&block)
            # No file-system locking needed for server-based databases
            yield
          end

          def ensure_database_directory_exists
            # No directory needed for server-based databases
            true
          end

          def test_workerize(db, test_worker_id)
            logical_name = name_template.logical_name(db)
            return db unless logical_name

            name_template.physical_name(logical_name, worker_id: test_worker_id)
          end

          def path_for(name)
            # For PostgreSQL, path is just the name (database or schema)
            name
          end

          def maintenance_db_name
            db_config.configuration_hash[:maintenance_database] || "postgres"
          end

        private
          def name_template
            @name_template ||= NameTemplate.new(db_config.database, label: "database")
          end

          def configured_test_worker_id
            db_config.test_worker_id if db_config.respond_to?(:test_worker_id)
          end
        end
      end
    end
  end
end
