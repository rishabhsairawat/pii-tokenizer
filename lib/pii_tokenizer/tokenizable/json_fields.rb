require 'active_support/concern'

module PiiTokenizer
  module Tokenizable
    # Module for handling tokenization of specific keys within JSON fields
    #
    # This module extends the PiiTokenizer::Tokenizable functionality to support
    # tokenizing specific keys within JSON columns. The tokenized values are stored
    # in a separate tokenized column (with "_token" suffix).
    #
    # @example Usage in an ActiveRecord model
    #   class Profile < ActiveRecord::Base
    #     include PiiTokenizer::Tokenizable
    #
    #     tokenize_pii fields: [:user_id],
    #                  entity_type: 'profile',
    #                  entity_id: ->(profile) { "profile_#{profile.id}" },
    #                  pii_types: { user_id: 'id' },
    #                  read_from_token_column: true
    #
    #     # Tokenize specific keys within the profile_details JSON column
    #     # Requires a profile_details_token column in the database
    #     tokenize_json_fields profile_details: {
    #       name: 'personal_name',
    #       email_id: 'email'
    #     }
    #   end
    #
    # @example Accessing tokenized JSON values
    #   profile = Profile.find(1)
    #
    #   # Access using the generated accessor methods
    #   name = profile.profile_details_name
    #   email = profile.profile_details_email_id
    #
    #   # Or decrypt the entire JSON field at once
    #   decrypted_data = profile.decrypt_json_field(:profile_details)
    #   name = decrypted_data['name']
    #   email = decrypted_data['email_id']
    #
    # @note This functionality requires:
    #   1. The model must call tokenize_pii first to set up entity_type and entity_id
    #   2. For each JSON field 'field', a corresponding 'field_token' column must exist
    #   3. Each key to be tokenized must have an explicitly defined PII type
    #   4. All non-tokenized fields are copied to the _token column for future compatibility
    module JsonFields
      extend ActiveSupport::Concern

      included do
        # Define class attributes
        class_attribute :json_tokenized_fields
        self.json_tokenized_fields = {}

        class_attribute :json_pii_types
        self.json_pii_types = {}
      end

      module ClassMethods
        # Configure tokenization for specific keys within JSON fields
        #
        # @param fields [Hash] a hash mapping JSON field names to key-PII type pairs
        #
        # @example With required PII types specified
        #   tokenize_json_fields profile_details: {
        #     name: 'personal_name',
        #     email_id: 'email',
        #     phone: 'telephone_number'
        #   }
        #
        # @note This method requires:
        #   1. The model must call tokenize_pii first
        #   2. A corresponding '_token' column must exist for each JSON field
        #   3. Each key must have an explicitly defined PII type
        def tokenize_json_fields(fields = {})
          # Validate that tokenize_pii has been called
          unless respond_to?(:entity_type_proc) && respond_to?(:entity_id_proc)
            raise ArgumentError, 'You must call tokenize_pii before tokenize_json_fields'
          end

          # Process and normalize the fields configuration
          normalized_fields = {}
          normalized_pii_types = {}

          fields.each do |field_name, config|
            field_str = field_name.to_s
            tokenized_column = "#{field_str}_token"

            # Validate that the tokenized column exists in the database
            unless column_names.include?(tokenized_column)
              raise ArgumentError, "Column '#{tokenized_column}' must exist in the database for JSON field tokenization"
            end

            if config.is_a?(Hash)
              # Keys is directly the hash mapping keys to PII types
              keys_with_pii_types = config

              # Store normalized configuration
              normalized_fields[field_str] = keys_with_pii_types.keys.map(&:to_s)
              normalized_pii_types[field_str] = {}

              keys_with_pii_types.each do |key, pii_type|
                if pii_type.blank?
                  raise ArgumentError, "Missing PII type for key '#{key}'. Each key must have an explicitly defined PII type."
                end

                normalized_pii_types[field_str][key.to_s] = pii_type.to_s
              end
            else
              # Invalid format
              raise ArgumentError, "Invalid format for JSON field tokenization. Please use the format: { json_field: { key1: 'pii_type1', key2: 'pii_type2' } }"
            end
          end

          # Store the normalized configuration
          self.json_tokenized_fields = normalized_fields
          self.json_pii_types = normalized_pii_types

          # Register before_save callback if not already registered
          unless _save_callbacks.map(&:filter).include?(:process_json_tokenization)
            before_save :process_json_tokenization
          end

          # Define accessors for each JSON field
          normalized_fields.each do |json_field, keys|
            keys.each do |key|
              # Define method to access decrypted value
              define_method("#{json_field}_#{key}") do
                json_data = self[json_field]
                tokenized_json = self["#{json_field}_token"]

                # Check if tokenized data exists
                if tokenized_json.present?
                  tokenized_json = begin
                                     tokenized_json.is_a?(Hash) ? tokenized_json : JSON.parse(tokenized_json.to_s)
                                   rescue StandardError
                                     {}
                                   end
                  if tokenized_json[key].present?
                    decrypt_json_value(json_field, key, tokenized_json[key])
                  elsif !self.class.read_from_token_column && json_data.present?
                    # If read_from_token_column is false AND the key is not in tokenized data, check original data
                    json_data = begin
                                  json_data.is_a?(Hash) ? json_data : JSON.parse(json_data.to_s)
                                rescue StandardError
                                  {}
                                end
                    json_data[key]
                  end
                elsif !self.class.read_from_token_column && json_data.present?
                  # If read_from_token_column is false AND no tokenized data, use original data
                  json_data = begin
                                json_data.is_a?(Hash) ? json_data : JSON.parse(json_data.to_s)
                              rescue StandardError
                                {}
                              end
                  json_data[key]
                end
              end
            end

            # If read_from_token_column is true, override the original attribute accessor
            # Using the same global setting as regular tokenized fields
            define_method(json_field) do
              # Check if we should read from token
              if self.class.read_from_token_column
                # Get the tokenized JSON data
                tokenized_json = read_attribute("#{json_field}_token")

                # If there's no tokenized data, return an empty hash instead of falling back to original
                return {} if tokenized_json.blank?

                # Ensure we're working with a hash
                tokenized_json = begin
                                   tokenized_json.is_a?(Hash) ? tokenized_json : JSON.parse(tokenized_json.to_s)
                                 rescue StandardError
                                   {}
                                 end

                # Create a new hash with decrypted values for tokenized fields
                decrypted_json = tokenized_json.dup

                # Process only the keys that are tokenized
                tokenized_keys = self.class.json_tokenized_fields[json_field.to_s]
                tokenized_keys.each do |key|
                  if tokenized_json[key].present?
                    decrypted_json[key] = decrypt_json_value(json_field, key, tokenized_json[key])
                  end
                end

                # Return the hash with decrypted values
                decrypted_json
              else
                # If read_from_token_column is false, use the original method
                read_attribute(json_field)
              end
            end
          end
        end
      end

      # Process JSON field tokenization before saving
      def process_json_tokenization
        return if self.class.json_tokenized_fields.empty?

        self.class.json_tokenized_fields.each do |json_field, keys|
          next unless respond_to?(json_field)

          json_data = read_attribute(json_field)
          next if json_data.blank?

          # Ensure we're working with a hash
          json_data = begin
                        json_data.is_a?(Hash) ? json_data : JSON.parse(json_data.to_s)
                      rescue StandardError
                        {}
                      end

          # Get or initialize tokenized data
          tokenized_column = "#{json_field}_token"
          tokenized_data = read_attribute(tokenized_column)
          tokenized_data = tokenized_data.present? ?
            (begin
               tokenized_data.is_a?(Hash) ? tokenized_data : JSON.parse(tokenized_data.to_s)
             rescue StandardError
               {}
             end) :
            {}

          modified = false

          # Copy all fields from the original JSON to tokenized column
          # This ensures we have a complete copy, not just the tokenized fields
          json_data.each do |key, value|
            # Skip keys that will be tokenized - they'll be handled separately
            next if keys.include?(key)

            # Copy non-tokenized keys as-is
            tokenized_data[key] = value
            modified = true
          end

          # Process each key that needs tokenization
          keys.each do |key|
            value = json_data[key]
            next if value.blank?

            # Skip if already tokenized and value hasn't changed
            next if tokenized_data[key].present? &&
                    (self.class.dual_write_enabled ? value == json_data[key] : true)

            # Get token for the value
            token = tokenize_json_value(json_field, key, value)
            next unless token

            # Store the token in the tokenized column
            tokenized_data[key] = token
            modified = true
          end

          # Update the tokenized column if modified
          write_attribute(tokenized_column, tokenized_data) if modified
        end
      end

      # Tokenize a specific value in a JSON field
      def tokenize_json_value(json_field, key, value)
        return nil if value.blank?

        # Get entity information from the model's configuration
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)

        # Get the PII type for this field/key - must be explicitly defined
        pii_type = self.class.json_pii_types.dig(json_field, key)
        return nil unless pii_type

        # Prepare the tokenization data
        tokens_data = [{
          value: value,
          entity_id: entity_id,
          entity_type: entity_type,
          field_name: "#{json_field}.#{key}",
          pii_type: pii_type
        }]

        # Call the encryption service
        key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)
        token_key = "#{entity_type.upcase}:#{entity_id}:#{pii_type}:#{value}"
        key_to_token[token_key]
      end

      # Decrypt a tokenized value from a JSON field
      def decrypt_json_value(json_field, key, token)
        return nil if token.blank?

        # Use caching for better performance
        cache_key = "#{json_field}.#{key}".to_sym
        return field_decryption_cache[cache_key] if field_decryption_cache.key?(cache_key)

        # Decrypt the token
        result = PiiTokenizer.encryption_service.decrypt_batch([token])
        decrypted_value = result[token]

        # Cache the decrypted value
        field_decryption_cache[cache_key] = decrypted_value if decrypted_value
        decrypted_value
      end

      # Decrypt all specified keys in a JSON field
      def decrypt_json_field(json_field)
        return {} unless self.class.json_tokenized_fields.key?(json_field.to_s)

        # Get original and tokenized data
        json_data = read_attribute(json_field)
        json_data = json_data.present? ?
          (begin
             json_data.is_a?(Hash) ? json_data : JSON.parse(json_data.to_s)
           rescue StandardError
             {}
           end) :
          {}

        tokenized_column = "#{json_field}_token"
        tokenized_data = read_attribute(tokenized_column)
        tokenized_data = tokenized_data.present? ?
          (begin
             tokenized_data.is_a?(Hash) ? tokenized_data : JSON.parse(tokenized_data.to_s)
           rescue StandardError
             {}
           end) :
          {}

        keys = self.class.json_tokenized_fields[json_field.to_s]
        result = {}

        # Include all non-tokenized fields from the tokenized column
        tokenized_data.each do |key, value|
          next if keys.include?(key)

          result[key] = value
        end

        # Process tokenized fields
        keys.each do |key|
          if tokenized_data[key].present?
            result[key] = decrypt_json_value(json_field, key, tokenized_data[key])
          elsif !self.class.read_from_token_column && json_data[key].present?
            # Only fall back to original data if read_from_token_column is false
            result[key] = json_data[key]
          end
        end

        result
      end
    end
  end
end
