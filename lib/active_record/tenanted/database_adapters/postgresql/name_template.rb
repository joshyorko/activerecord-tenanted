# frozen_string_literal: true

module ActiveRecord
  module Tenanted
    module DatabaseAdapters
      module PostgreSQL
        class NameTemplate
          PLACEHOLDER = "%{tenant}"
          IDENTIFIER_BYTE_LIMIT = 63

          def initialize(pattern, label:)
            @pattern = pattern.to_s
            unless @pattern.scan(PLACEHOLDER).length == 1
              raise ActiveRecord::Tenanted::ConfigurationError,
                "#{label} must contain exactly one %{tenant} placeholder"
            end

            prefix, suffix = @pattern.split(PLACEHOLDER, 2)
            @matcher = /\A#{Regexp.escape(prefix)}([\s\S]+)#{Regexp.escape(suffix)}\z/
          end

          def physical_name(tenant, worker_id: nil)
            logical_name = tenant.to_s
            if logical_name.empty?
              raise ActiveRecord::Tenanted::BadTenantNameError, "PostgreSQL tenant name cannot be empty"
            end

            physical_name = @pattern.sub(PLACEHOLDER, logical_name)
            physical_name += worker_suffix(worker_id, logical_name.bytesize) if worker_id
            if physical_name.include?("\0")
              raise ActiveRecord::Tenanted::BadTenantNameError, "PostgreSQL identifier cannot contain NUL"
            end
            if physical_name.bytesize > IDENTIFIER_BYTE_LIMIT
              raise ActiveRecord::Tenanted::BadTenantNameError,
                "PostgreSQL identifier exceeds 63 bytes: #{physical_name.inspect}"
            end

            physical_name
          end

          def logical_name(physical, worker_id: nil)
            physical_name = physical.to_s
            expected_length = nil

            if worker_id
              match = worker_matcher(worker_id).match(physical_name)
              return unless match

              physical_name = match[:physical]
              expected_length = match[:length].to_i(36)
            end

            logical_name = @matcher.match(physical_name)&.[](1)
            return unless logical_name
            return if expected_length && logical_name.bytesize != expected_length

            logical_name
          end

        private
          def worker_suffix(worker_id, logical_name_bytesize)
            "~w#{Integer(worker_id).to_s(36)}~l#{logical_name_bytesize.to_s(36)}"
          end

          def worker_matcher(worker_id)
            prefix = Regexp.escape("~w#{Integer(worker_id).to_s(36)}~l")
            /\A(?<physical>[\s\S]+)#{prefix}(?<length>[0-9a-z]+)\z/
          end
        end
      end
    end
  end
end
