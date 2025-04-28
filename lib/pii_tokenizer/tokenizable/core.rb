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
        before_save :encrypt_pii_fields if respond_to?(:before_save)
        after_save :process_after_save_tokenization if respond_to?(:after_save)
        after_find :register_for_decryption if respond_to?(:after_find)
        after_initialize :register_for_decryption if respond_to?(:after_initialize)
      end

      class_methods do
        # Configure tokenization for this model
        def tokenize_pii(fields:, entity_type:, entity_id:, dual_write: false, read_from_token: nil)
          # Convert to string keys for consistency
          fields_hash = {}

          # If read_from_token is not explicitly set, default to true when dual_write is false
          read_from_token = !dual_write if read_from_token.nil?

          # Handle both array of fields and hash mapping fields to pii_types
          if fields.is_a?(Hash)
            fields.each do |k, v|
              fields_hash[k.to_s] = v
            end
            field_list = fields.keys
          else
            # Default to uppercase field name if not specified
            fields.each do |field|
              fields_hash[field.to_s] = field.to_s.upcase
            end
            field_list = fields
          end

          # Set class attributes
          self.pii_types = fields_hash
          self.tokenized_fields = field_list.map(&:to_sym)
          self.dual_write_enabled = dual_write
          self.read_from_token_column = read_from_token

          # Store entity_type as a proc
          self.entity_type_proc = if entity_type.is_a?(Proc)
                                    entity_type
                                  else
                                    ->(_) { entity_type.to_s }
                                  end

          # Store entity_id as a proc
          self.entity_id_proc = entity_id

          # Define field accessors
          define_field_accessors
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