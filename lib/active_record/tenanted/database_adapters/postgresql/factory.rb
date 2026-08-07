# frozen_string_literal: true

module ActiveRecord
  module Tenanted
    module DatabaseAdapters
      module PostgreSQL
        # Factory for creating the appropriate PostgreSQL adapter based on strategy
        #
        # The strategy is inferred from the database name:
        # - If database name contains `%{tenant}` → "database" strategy
        # - Otherwise → "schema" strategy (colocated)
        #
        # Strategies:
        # - "schema" (default): Uses schema-based multi-tenancy
        # - "database": Uses database-based multi-tenancy
        class Factory
          def self.new(db_config)
            database_pattern = db_config.database.to_s
            schema_pattern = db_config.configuration_hash[:schema_name_pattern]

            if database_pattern.include?(NameTemplate::PLACEHOLDER) && schema_pattern
              raise ActiveRecord::Tenanted::ConfigurationError,
                "Configure exactly one PostgreSQL tenant template in database or schema_name_pattern"
            elsif database_pattern.include?(NameTemplate::PLACEHOLDER)
              NameTemplate.new(database_pattern, label: "database")
              Database.new(db_config)
            elsif schema_pattern
              NameTemplate.new(schema_pattern, label: "schema_name_pattern")
              Schema.new(db_config)
            else
              raise ActiveRecord::Tenanted::ConfigurationError,
                "Configure exactly one PostgreSQL tenant template; static databases require schema_name_pattern"
            end
          end
        end
      end
    end
  end
end
