require 'active_support/concern'

module PiiTokenizer
  module Tokenizable
    module BatchOperations
      extend ActiveSupport::Concern

      # Extension module for ActiveRecord::Relation
      module DecryptedFieldsExtension
        # Set fields to decrypt when relation is loaded
        def decrypt_fields(fields)
          @decrypt_fields = fields
          self
        end

        # Override to_a to preload decrypted fields
        def to_a
          records = super
          if @decrypt_fields&.any?
            # Preload decrypted fields in batch for all records
            model = klass
            model.preload_decrypted_fields(records, @decrypt_fields)
          end
          records
        end
      end

      class_methods do
        # Preload decrypted values for a collection of records
        def preload_decrypted_fields(records, *fields)
          fields = fields.flatten.map(&:to_sym)
          fields_to_decrypt = fields & tokenized_fields
          return if fields_to_decrypt.empty? || records.empty?

          # Collect all tokens that need decryption
          tokens_to_decrypt = []
          record_token_map = {}

          records.each do |record|
            fields_to_decrypt.each do |field|
              token_column = "#{field}_token"
              next unless record.respond_to?(token_column) && record.send(token_column).present?

              token = record.send(token_column)
              tokens_to_decrypt << token

              # Map token back to record and field
              record_token_map[token] ||= []
              record_token_map[token] << [record, field]
            end
          end

          return if tokens_to_decrypt.empty?

          # Make a single batch request to decrypt all tokens
          decrypted_values = PiiTokenizer.encryption_service.decrypt_batch(tokens_to_decrypt)

          # Update each record's cache with its decrypted values
          decrypted_values.each do |token, value|
            next unless record_token_map[token]

            record_token_map[token].each do |record, field|
              record.field_decryption_cache[field] = value
            end
          end
        end

        # Chainable method to include decrypted fields in query results
        def include_decrypted_fields(*fields)
          fields = fields.flatten.map(&:to_sym)

          # Store the fields to decrypt in the relation's context
          all.extending(DecryptedFieldsExtension).decrypt_fields(fields)
        end
      end
    end
  end
end
