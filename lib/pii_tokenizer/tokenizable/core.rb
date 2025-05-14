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
        # @param fields [Array<Symbol>, Hash<Symbol, String>] Fields to tokenize, either as array or hash mapping to PII types
        # @param entity_type [String, Proc] The entity type for this model, either as string or proc returning a string
        # @param entity_id [Proc] A proc that always returns a valid entity_id for a record (required)
        # @param dual_write [Boolean] Whether to write both to token and original columns (default: false)
        # @param read_from_token [Boolean] Whether to read from token columns (default: !dual_write)
        #
        # @example Simple configuration
        #   tokenize_pii fields: [:first_name, :last_name, :email],
        #               entity_type: 'user_uuid',
        #               entity_id: ->(user) { "user_#{user.external_id}" }
        #
        # @example With PII types
        #   tokenize_pii fields: { first_name: 'NAME', last_name: 'NAME', email: 'EMAIL' },
        #               entity_type: 'user_uuid',
        #               entity_id: ->(user) { "user_#{user.external_id}" }
        #
        # @note The entity_id proc must always return a valid entity_id string
        def tokenize_pii(fields:, entity_type:, entity_id:, dual_write: false, read_from_token: nil)
          # If read_from_token is not explicitly set, default to true when dual_write is false
          read_from_token = !dual_write if read_from_token.nil?

          # Set tokenized fields and PII types
          if fields.is_a?(Hash)
            self.pii_types = fields.transform_keys(&:to_s)
            self.tokenized_fields = fields.keys.map(&:to_sym)
          else
            # Default to uppercase field name if not specified
            self.pii_types = fields.map { |f| [f.to_s, f.to_s.upcase] }.to_h
            self.tokenized_fields = fields.map(&:to_sym)
          end

          # Set tokenization options
          self.dual_write_enabled = dual_write
          self.read_from_token_column = read_from_token

          # Store entity_type as a proc
          self.entity_type_proc = entity_type.is_a?(Proc) ? entity_type : ->(_) { entity_type.to_s }

          # Store entity_id as a proc - we assume this will always return a valid entity_id
          self.entity_id_proc = entity_id

          # Define accessors for each field
          define_field_accessors

          # Register the encrypt_pii_fields callback to run last in the before_save chain
          register_encrypt_pii_fields_callback
        end

        # Register the encrypt_pii_fields callback to ensure it runs last
        # in the before_save callback chain
        def register_encrypt_pii_fields_callback
          if respond_to?(:before_save)
            # Use prepend: false (default) to ensure this runs last in the before_save chain
            # This is important so that any fields populated by other callbacks
            # are properly tokenized
            before_save :encrypt_pii_fields, prepend: false
          end
        end

        # Getter for the decryption cache
        def decryption_cache
          @decryption_cache ||= {}
        end

        # Setter for the decryption cache
        def decryption_cache=(value)
          @decryption_cache = value
        end

        # Generate a token column name for a field
        def token_column_for(field)
          "#{field}_token"
        end
      end
    end
  end
end
