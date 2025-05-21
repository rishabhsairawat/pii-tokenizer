require 'active_support/concern'

module PiiTokenizer
  module Tokenizable
    module Core
      extend ActiveSupport::Concern

      included do
        # Define class attributes
        class_attribute :tokenized_fields
        self.tokenized_fields = []

        class_attribute :entity_type_proc
        class_attribute :entity_id_proc

        class_attribute :pii_types
        self.pii_types = {}

        class_attribute :dual_write_enabled
        self.dual_write_enabled = false

        class_attribute :read_from_token_column
        self.read_from_token_column = true # Default to true

        # Set up callbacks if the class supports them
        # The encrypt_pii_fields callback is now registered in tokenize_pii to ensure proper ordering
        after_find :register_for_decryption if respond_to?(:after_find)
        after_initialize :register_for_decryption if respond_to?(:after_initialize)
      end

      class_methods do
        # Configure tokenization for this model
        #
        # @param fields [Hash<Symbol, String>] Fields to tokenize, as a hash mapping field names to PII types
        #   It's recommended to use predefined types from PiiTokenizer::PiiTypes (e.g., PiiTokenizer::PiiTypes::NAME)
        # @param entity_type [String, Proc] The entity type for this model, either as string or proc returning a string
        #   It's recommended to use predefined types from PiiTokenizer::EntityTypes (e.g., PiiTokenizer::EntityTypes::USER_UUID)
        # @param entity_id [Proc] A proc that always returns a valid entity_id for a record (required)
        # @param dual_write [Boolean] Whether to write both to token and original columns (default: false)
        # @param read_from_token [Boolean] Whether to read from token columns (default: !dual_write)
        #
        # @example With PII types and entity types (recommended)
        #   tokenize_pii fields: {
        #     first_name: PiiTokenizer::PiiTypes::NAME,
        #     last_name: PiiTokenizer::PiiTypes::NAME,
        #     email: PiiTokenizer::PiiTypes::EMAIL
        #   },
        #   entity_type: PiiTokenizer::EntityTypes::USER_UUID,
        #   entity_id: ->(user) { "user_#{user.external_id}" }
        #
        # @note The entity_id proc must always return a valid entity_id string
        def tokenize_pii(fields:, entity_type:, entity_id:, dual_write: false, read_from_token: nil)
          # Set default read_from_token behavior based on dual_write setting
          read_from_token = !dual_write if read_from_token.nil?

          # Configure tokenization settings
          configure_tokenized_fields(fields)
          configure_entity_identification(entity_type, entity_id)
          configure_persistence_behavior(dual_write, read_from_token)

          # Setup accessors and callbacks
          define_field_accessors
          register_encrypt_pii_fields_callback
        end

        # Register the encrypt_pii_fields callback to ensure it runs last
        # in the before_save callback chain
        def register_encrypt_pii_fields_callback
          return unless respond_to?(:before_save)

          # Use prepend: false (default) to ensure this runs last in the before_save chain
          # This is important so that any fields populated by other callbacks are properly tokenized
          before_save :encrypt_pii_fields, prepend: false
        end

        # Generate a token column name for a field
        def token_column_for(field)
          "#{field}_token"
        end

        # Configure fields to be tokenized and their PII types
        def configure_tokenized_fields(fields)
          unless fields.is_a?(Hash)
            raise ArgumentError, "Fields must be provided as a hash mapping field names to PII types, e.g. { first_name: 'NAME', email: 'EMAIL' }"
          end

          # Validate PII types - always required
          invalid_types = []

          fields.each do |field, pii_type|
            unless PiiTokenizer::PiiTypes.supported?(pii_type)
              invalid_types << "#{field}: #{pii_type}"
            end
          end

          if invalid_types.any?
            supported_types = PiiTokenizer::PiiTypes.all.join(', ')
            raise ArgumentError, "Invalid PII types detected: #{invalid_types.join(', ')}. " \
                                "Supported types are: #{supported_types}"
          end

          # Fields provided as a hash with explicit PII types
          self.pii_types = fields.transform_keys(&:to_s)
          self.tokenized_fields = fields.keys.map(&:to_sym)
        end

        # Configure entity type and ID used for tokenization
        def configure_entity_identification(entity_type, entity_id)
          # Validate entity type if it's a string constant
          if entity_type.is_a?(String)
            unless PiiTokenizer::EntityTypes.supported?(entity_type.upcase)
              supported_types = PiiTokenizer::EntityTypes.all.join(', ')
              raise ArgumentError, "Invalid entity type: #{entity_type}. " \
                                  "Supported types are: #{supported_types}"
            end
          end

          # Store entity_type as a proc so it can be dynamically evaluated
          self.entity_type_proc = entity_type.is_a?(Proc) ? entity_type : ->(_) { entity_type.to_s }

          # Store entity_id as a proc - this should always return a valid entity_id
          self.entity_id_proc = entity_id
        end

        # Configure how tokenized data is persisted and accessed
        def configure_persistence_behavior(dual_write, read_from_token)
          self.dual_write_enabled = dual_write
          self.read_from_token_column = read_from_token
        end
      end
    end
  end
end
