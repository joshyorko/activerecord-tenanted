# frozen_string_literal: true

module ActiveRecord
  module Tenanted
    module DatabaseAdapters
      module PostgreSQL
        # PostgreSQL adapter using schema-based multi-tenancy
        #
        # Instead of creating separate databases per tenant, this adapter creates
        # separate schemas within a single PostgreSQL database. This is more efficient
        # and aligns with PostgreSQL best practices.
        #
        # Configuration example:
        #
        # Colocated approach (recommended):
        #   adapter: postgresql
        #   tenanted: true
        #   database: myapp_production
        #
        # The adapter will:
        # - Connect to a single base database
        # - Create/use schemas for tenant isolation
        # - Set schema_search_path to isolate tenants
        class Schema < Base
          include Colocated

          def initialize(db_config)
            super
          end

          def tenant_databases
            with_base_connection do |connection|
              result = connection.execute(<<~SQL)
                SELECT nspname AS schema_name
                FROM pg_namespace
                ORDER BY nspname
              SQL

              result.filter_map do |row|
                schema_name = row["schema_name"] || row[0]
                next if reserved_schema?(schema_name)

                tenant_name = name_template.logical_name(schema_name, worker_id: configured_test_worker_id)
                next unless tenant_name

                tenant_name
              end
            end
          end

          def create_database
            # Create schema instead of database
            schema = database_path

            with_base_connection do |connection|
              quoted_schema = connection.quote_table_name(schema)
              connection.create_schema(schema, if_not_exists: true)

              # Commit any pending transaction to ensure schema is visible to other connections
              # with_temporary_connection may wrap DDL in a transaction
              connection.commit_db_transaction if connection.transaction_open?

              # Grant usage permissions (optional but good practice)
              # This ensures the schema can be used by the current user
              username = db_config.configuration_hash[:username] || "postgres"
              connection.execute("GRANT ALL ON SCHEMA #{quoted_schema} TO #{connection.quote_table_name(username)}")
            end
          end

          def drop_database
            # Drop schema instead of database
            schema = database_path

            with_base_connection do |connection|
              # CASCADE ensures all objects in the schema are dropped
              connection.execute("DROP SCHEMA IF EXISTS #{connection.quote_table_name(schema)} CASCADE")
            end
          end

          def create_colocated_database
            # Create the colocated database that will contain all tenant schemas.
            # Use Rails' DatabaseTasks.create to fully integrate with Rails
            base_db_name = extract_base_database_name

            # Create a non-tenanted database config for the base database
            # We strip out tenanted-specific keys to create a regular Rails
            # config Rails' create method will handle connection, logging, etc.
            base_config_hash = db_config.configuration_hash
              .except(:tenanted, :tenant_schema, :schema_search_path)
              .merge(database: base_db_name)

            base_create_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
              db_config.env_name,
              db_config.name,
              base_config_hash
            )

            ActiveRecord::Tasks::DatabaseTasks.create(base_create_config)
          end

          def drop_colocated_database
            # Drop the entire colocated database using Rails' DatabaseTasks.drop
            # to fully integrate with Rails
            base_db_name = extract_base_database_name

            # Create a non-tenanted database config for the base database
            # We strip out tenanted-specific keys to create a regular Rails config
            # Rails' drop method will handle connection, termination, logging, etc.
            base_config_hash = db_config.configuration_hash
              .except(:tenanted, :tenant_schema, :schema_search_path)
              .merge(database: base_db_name)

            base_drop_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
              db_config.env_name,
              db_config.name,
              base_config_hash
            )

            ActiveRecord::Tasks::DatabaseTasks.drop(base_drop_config)
          end

          def database_exist?
            # Check if schema exists
            schema = database_path

            with_base_connection do |connection|
              result = connection.execute(<<~SQL)
                SELECT 1#{' '}
                FROM information_schema.schemata#{' '}
                WHERE schema_name = '#{connection.quote_string(schema)}'
              SQL
              result.any?
            end
          end

          def database_path
            # Returns the schema name for this tenant
            # For PostgreSQL with schema-based tenancy, we store the schema name separately
            # because db_config.database is the base database name
            db_config.configuration_hash[:tenant_schema] ||
              raise(ActiveRecord::Tenanted::NoTenantError, "PostgreSQL tenant_schema not set")
          end

          # Prepare tenant config hash with schema-specific settings
          def prepare_tenant_config_hash(config_hash, base_config, tenant_name)
            worker_id = base_config.test_worker_id if base_config.respond_to?(:test_worker_id)
            schema_name = name_template.physical_name(tenant_name, worker_id: worker_id)
            database_name = base_config.database

            config_hash.merge(
              schema_search_path: schema_name,
              tenant_schema: schema_name,
              database: database_name
            )
          end

          def identifier_for(tenant_name)
            name_template.physical_name(tenant_name)
          end

        private
          def name_template
            @name_template ||= NameTemplate.new(
              db_config.configuration_hash[:schema_name_pattern],
              label: "schema_name_pattern"
            )
          end

          def reserved_schema?(schema_name)
            schema_name == "public" || schema_name == "information_schema" || schema_name.start_with?("pg_")
          end

          def with_base_connection(&block)
            # Connect to the base database (without tenant-specific schema)
            # This allows us to create/drop/query schemas

            # Ensure the base database exists first
            ensure_base_database_exists

            ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(base_db_config, &block)
          end

          def ensure_base_database_exists
            # Check if base database exists, create if not
            base_db_name = extract_base_database_name

            # Connect to postgres maintenance database to check/create base database
            maintenance_config = db_config.configuration_hash.dup.merge(
              database: maintenance_db_name,
              database_tasks: false
            )
            maintenance_db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
              db_config.env_name,
              "_maint_#{db_config.name}",
              maintenance_config
            )

            ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(maintenance_db_config) do |connection|
              result = connection.execute("SELECT 1 FROM pg_database WHERE datname = '#{connection.quote_string(base_db_name)}'")
              unless result.any?
                # Create base database if it doesn't exist
                Rails.logger.info "Creating base PostgreSQL database: #{base_db_name}"
                create_options = {}
                create_options[:encoding] = db_config.configuration_hash[:encoding] if db_config.configuration_hash.key?(:encoding)
                create_options[:collation] = db_config.configuration_hash[:collation] if db_config.configuration_hash.key?(:collation)

                # CREATE DATABASE cannot run inside a transaction block in PostgreSQL
                # Force commit any existing transaction, then use raw connection
                connection.commit_db_transaction if connection.transaction_open?

                encoding_clause = create_options[:encoding] ? " ENCODING '#{create_options[:encoding]}'" : ""
                collation_clause = create_options[:collation] ? " LC_COLLATE '#{create_options[:collation]}'" : ""

                connection.raw_connection.exec("CREATE DATABASE #{connection.quote_table_name(base_db_name)}#{encoding_clause}#{collation_clause}")
              end
            end
          rescue StandardError => e
            Rails.logger.error "Failed to ensure base database exists: #{e.class}: #{e.message}"
            raise
          end

          def base_db_config
            # Create a config for the base database
            # We extract the base database name from the pattern
            base_db_name = extract_base_database_name

            configuration_hash = db_config.configuration_hash.dup.merge(
              database: base_db_name,
              database_tasks: false,
              schema_search_path: "public" # Use public schema for admin operations
            )

            ActiveRecord::DatabaseConfigurations::HashConfig.new(
              db_config.env_name,
              "_tmp_#{db_config.name}",
              configuration_hash
            )
          end

          def extract_base_database_name
            db_config.database
          end
        end
      end
    end
  end
end
