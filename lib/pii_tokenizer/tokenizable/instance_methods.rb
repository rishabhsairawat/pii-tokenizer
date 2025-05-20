require 'active_support/concern'

module PiiTokenizer
  module Tokenizable
    module InstanceMethods
      extend ActiveSupport::Concern

      # --- Field Cache Management ---

      def field_decryption_cache
        @field_decryption_cache ||= {}
      end

      def clear_decryption_cache
        @field_decryption_cache = {}
      end

      def cache_decrypted_value(field, value)
        field_decryption_cache[field.to_sym] = value
      end

      def get_cached_decrypted_value(field)
        field_decryption_cache[field.to_sym]
      end

      # --- Entity Information ---

      def entity_type
        self.class.entity_type_proc.call(self)
      end

      def entity_id
        self.class.entity_id_proc.call(self)
      end

      # --- Field Status Utilities ---

      def field_set_to_nil?(field)
        field_var = "@#{field}_set_to_nil"
        instance_variable_defined?(field_var) && instance_variable_get(field_var)
      end

      def token_column_for(field)
        "#{field}_token"
      end

      # --- Decryption Methods ---

      def register_for_decryption
        return if (self.class.tokenized_fields.empty? &&
                  (!defined?(self.class.json_tokenized_fields) || self.class.json_tokenized_fields.empty?)) ||
                  new_record?

        clear_decryption_cache
      end

      def decrypt_field(field)
        field_sym = field.to_sym
        return nil unless self.class.tokenized_fields.include?(field_sym)
        return nil if field_set_to_nil?(field_sym)

        # Check cache first
        return field_decryption_cache[field_sym] if field_decryption_cache.key?(field_sym)

        # If this is the first access to any tokenized field, load all tokenized fields at once
        if field_decryption_cache.empty?
          # Get all regular tokenized fields
          decrypt_all_fields
          return field_decryption_cache[field_sym] if field_decryption_cache.key?(field_sym)
        end

        # If we still don't have the field in cache (rare case), get it individually
        token_column = token_column_for(field)
        encrypted_value = get_encrypted_value(field_sym, token_column)

        return encrypted_value if encrypted_value.blank?

        result = PiiTokenizer.encryption_service.decrypt_batch([encrypted_value])
        decrypted_value = result[encrypted_value] || read_attribute(field)

        # Cache and return
        field_decryption_cache[field_sym] = decrypted_value
        decrypted_value
      end

      def decrypt_fields(*fields)
        fields = fields.flatten.map(&:to_sym)
        fields_to_decrypt = fields & self.class.tokenized_fields
        return {} if fields_to_decrypt.empty?

        # Collect encrypted values
        field_to_encrypted = {}
        encrypted_values = []

        fields_to_decrypt.each do |field|
          next if field_set_to_nil?(field)

          token_column = token_column_for(field)
          encrypted_value = get_encrypted_value(field, token_column)
          next if encrypted_value.blank?

          field_to_encrypted[field] = encrypted_value
          encrypted_values << encrypted_value
        end

        return {} if encrypted_values.empty?

        # Batch decrypt
        decrypted_values = PiiTokenizer.encryption_service.decrypt_batch(encrypted_values)

        # Map results
        result = {}
        field_to_encrypted.each do |field, encrypted|
          decrypted = decrypted_values[encrypted]
          if decrypted
            result[field] = decrypted
            field_decryption_cache[field] = decrypted
          else
            result[field] = read_attribute(field)
          end
        end

        result
      end

      # New method to decrypt all tokenized fields (both regular and JSON) in a single batch
      def decrypt_all_fields
        return if self.class.tokenized_fields.empty? &&
                  (!defined?(self.class.json_tokenized_fields) || self.class.json_tokenized_fields.empty?)

        # 1. Collect all tokens that need decryption
        tokens_to_decrypt = []
        token_field_map = {}
        unique_tokens = {}

        # Process regular tokenized fields
        self.class.tokenized_fields.each do |field|
          next if field_set_to_nil?(field)

          token_column = token_column_for(field)
          encrypted_value = get_encrypted_value(field, token_column)
          next if encrypted_value.blank?

          # Skip duplicates to avoid redundant decryption requests
          next if unique_tokens[encrypted_value]

          unique_tokens[encrypted_value] = true

          tokens_to_decrypt << encrypted_value
          token_field_map[encrypted_value] = [field]
        end

        # Process JSON tokenized fields if available
        if defined?(self.class.json_tokenized_fields) && self.class.json_tokenized_fields.any?
          self.class.json_tokenized_fields.each do |json_field, keys|
            tokenized_column = "#{json_field}_token"
            next unless respond_to?(tokenized_column) && self[tokenized_column].present?

            tokenized_data = begin
                               self[tokenized_column].is_a?(Hash) ? self[tokenized_column] : JSON.parse(self[tokenized_column].to_s)
                             rescue StandardError
                               {}
                             end

            keys.each do |key|
              next unless tokenized_data[key].present?

              token = tokenized_data[key]

              # Skip duplicates but add this field to the mapping for the token
              if unique_tokens[token]
                # Add this JSON field to the existing token mapping
                field_key = "#{json_field}.#{key}"
                existing_token_fields = token_field_map[token]
                existing_token_fields << field_key unless existing_token_fields.include?(field_key)
                next
              end

              unique_tokens[token] = true
              tokens_to_decrypt << token
              token_field_map[token] = ["#{json_field}.#{key}"]
            end
          end
        end

        return if tokens_to_decrypt.empty?

        # 2. Batch decrypt
        decrypted_values = PiiTokenizer.encryption_service.decrypt_batch(tokens_to_decrypt)

        # 3. Update cache with results
        decrypted_values.each do |token, value|
          field_keys = token_field_map[token]
          next unless field_keys

          field_keys.each do |field_key|
            # Convert field_key to string before checking for '.'
            field_key_str = field_key.to_s

            field_decryption_cache[field_key.to_sym] = if field_key_str.include?('.')
                                                         # JSON field, store with the special key format
                                                         value
                                                       else
                                                         # Regular field
                                                         value
                                                       end
          end
        end
      end

      # --- Encryption Methods ---

      def encrypt_pii_fields
        # Skip if no tokenized fields and no JSON tokenized fields
        return if self.class.tokenized_fields.empty? &&
                  (!defined?(self.class.json_tokenized_fields) || self.class.json_tokenized_fields.empty?)

        # Track if we need to process regular fields
        regular_fields_processed = true

        # For existing records, check if tokenized fields changed
        unless self.class.tokenized_fields.empty?
          # Early return for unchanged persisted records - this is an optimization
          # But always process for new records
          if !new_record? && !tokenized_field_changes? && all_fields_have_tokens?
            regular_fields_processed = false
          end
        end

        # Check if JSON fields need processing
        json_fields_to_process = []
        if defined?(self.class.json_tokenized_fields) && self.class.json_tokenized_fields.any?
          self.class.json_tokenized_fields.each do |json_field, _keys|
            next unless respond_to?(json_field)

            json_data = read_attribute(json_field)
            next if json_data.blank?

            # Only process JSON fields that have changed
            if !new_record? && !json_field_changed?(json_field)
              next
            end

            json_fields_to_process << json_field
          end
        end

        # If nothing to process, return early
        return if !regular_fields_processed && json_fields_to_process.empty?

        # Handle dual_write by preserving original values for regular fields
        preserve_original_values if self.class.dual_write_enabled && regular_fields_processed

        # Get entity information (common for both regular and JSON fields)
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)

        # Prepare a single batch for all tokenization operations
        tokens_data = []
        fields_to_clear = []
        json_field_updates = {}

        # Process regular fields
        if regular_fields_processed
          fields_to_process = fields_needing_tokenization

          # Add regular fields to the batch
          fields_to_process.each do |field|
            token_column = token_column_for(field)

            # Check if this field was explicitly set to nil
            if field_set_to_nil?(field)
              # Get the current value to see if a callback might have populated it
              db_value = read_attribute(field.to_s)

              if db_value.present?
                # A callback populated this field after it was set to nil - we should tokenize it
                instance_variable_set("@#{field}_set_to_nil", false)
                value = db_value
              else
                # Field is still nil, proceed with clearing it
                fields_to_clear << field
                next
              end
            else
              # Normal case, get field value
              value = get_field_value(field)

              # Handle nil values
              if value.nil?
                fields_to_clear << field
                next
              end
            end

            # Handle empty strings without calling encryption service
            if value.respond_to?(:blank?) && value.blank?
              safe_write_attribute(token_column, '')
              next
            end

            # Skip blank values only if dual_write is disabled
            next if !self.class.dual_write_enabled && value.respond_to?(:blank?) && value.blank?

            # Get PII type
            pii_type = self.class.pii_types[field.to_s]
            next if pii_type.blank?

            # Add to tokenization batch
            tokens_data << {
              value: value,
              entity_id: entity_id,
              entity_type: entity_type,
              field_name: field.to_s,
              pii_type: pii_type,
              type: :regular
            }
          end
        end

        # Process JSON fields
        json_fields_to_process.each do |json_field|
          keys = self.class.json_tokenized_fields[json_field.to_s]
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

            # Only copy non-tokenized keys if they're different or missing
            if !tokenized_data.key?(key) || tokenized_data[key] != value
              tokenized_data[key] = value
              modified = true
            end
          end

          # Get previous JSON data if this is an update
          previous_json_data = {}
          if !new_record? && respond_to?(:attribute_before_last_save)
            # Rails 5.1+
            prev_data = attribute_before_last_save(json_field.to_s)
            if prev_data.present?
              previous_json_data = begin
                                     prev_data.is_a?(Hash) ? prev_data : JSON.parse(prev_data.to_s)
                                   rescue StandardError
                                     {}
                                   end
            end
          end

          # Add JSON fields to the batch
          keys.each do |key|
            value = json_data[key]
            next if value.blank?

            # Skip if not a new record and value hasn't changed
            if !new_record? && previous_json_data[key] == value &&
               tokenized_data.key?(key) && tokenized_data[key].present?
              next
            end

            # Get the PII type for this field/key
            pii_type = self.class.json_pii_types.dig(json_field, key)
            next unless pii_type

            # Add to batch tokenization data
            tokens_data << {
              value: value,
              entity_id: entity_id,
              entity_type: entity_type,
              field_name: "#{json_field}.#{key}",
              pii_type: pii_type,
              type: :json,
              json_field: json_field,
              json_key: key
            }

            modified = true
          end

          # Store tokenized data for later update
          json_field_updates[json_field] = {
            tokenized_data: tokenized_data,
            modified: modified
          }
        end

        # Process nil fields
        clear_token_fields(fields_to_clear) unless fields_to_clear.empty?

        # Skip if no tokens to process
        return if tokens_data.empty?

        # Process tokens in batch - this is the single API call for both regular and JSON fields
        values_for_encryption = tokens_data.map do |data|
          {
            value: data[:value],
            entity_id: data[:entity_id],
            entity_type: data[:entity_type],
            field_name: data[:field_name],
            pii_type: data[:pii_type]
          }
        end

        key_to_token = PiiTokenizer.encryption_service.encrypt_batch(values_for_encryption)

        # Now apply the tokens to the respective fields
        update_model_with_combined_tokens(tokens_data, key_to_token, json_field_updates)

        # Restore original values if dual_write is enabled
        restore_original_values if self.class.dual_write_enabled && regular_fields_processed
      end

      # New method to update model with tokens from combined batch operation
      def update_model_with_combined_tokens(tokens_data, key_to_token, json_field_updates)
        tokens_data.each do |token_data|
          value = token_data[:value]

          # Generate key
          entity_type = token_data[:entity_type].upcase
          entity_id = token_data[:entity_id]
          pii_type = token_data[:pii_type]

          key = "#{entity_type}:#{entity_id}:#{pii_type}:#{value}"
          token = key_to_token[key]
          next unless token

          if token_data[:type] == :regular
            # Regular field
            field = token_data[:field_name]
            field_sym = field.to_sym

            # Update token column
            token_column = token_column_for(field_sym)
            safe_write_attribute(token_column, token)

            # Handle original column based on dual_write mode
            if self.class.dual_write_enabled
              if value.present?
                safe_write_attribute(field, value)
              end
            else
              # When dual_write is off, we don't write to the original field
              # Just store the value in the instance variable for decryption
              instance_variable_set("@original_#{field_sym}", value)
            end

            # Update cache and mark as changed
            field_decryption_cache[field_sym] = value if value.present?

            if respond_to?(:attribute_will_change!)
              send(:attribute_will_change!, token_column)
              send(:attribute_will_change!, field) if self.class.dual_write_enabled
            end
          else
            # JSON field
            json_field = token_data[:json_field]
            key = token_data[:json_key]

            # Update the token in the tokenized data
            field_update = json_field_updates[json_field]
            next unless field_update && field_update[:modified]

            field_update[:tokenized_data][key] = token

            # Update cache
            cache_key = "#{json_field}.#{key}".to_sym
            field_decryption_cache[cache_key] = value if value.present?
          end
        end

        # Apply JSON field updates
        json_field_updates.each do |json_field, update_info|
          next unless update_info[:modified]

          tokenized_column = "#{json_field}_token"
          safe_write_attribute(tokenized_column, update_info[:tokenized_data])

          if respond_to?(:attribute_will_change!)
            send(:attribute_will_change!, tokenized_column)
          end
        end
      end

      private

      # --- Helper Methods ---

      def preserve_original_values
        self.class.tokenized_fields.each do |field|
          field_str = field.to_s
          original_value = read_attribute(field_str)
          if original_value.present?
            instance_variable_set("@_preserve_original_#{field}", original_value)
            field_decryption_cache[field] = original_value
          end
        end
      end

      def restore_original_values
        self.class.tokenized_fields.each do |field|
          field_str = field.to_s
          next unless instance_variable_defined?("@_preserve_original_#{field}")

          preserved_value = instance_variable_get("@_preserve_original_#{field}")
          safe_write_attribute(field_str, preserved_value)
          remove_instance_variable("@_preserve_original_#{field}")
        end
      end

      def get_encrypted_value(field, token_column)
        if self.class.read_from_token_column && respond_to?(token_column) && !self[token_column].nil?
          self[token_column]
        else
          read_attribute(field)
        end
      end

      def tokenized_field_changes?
        self.class.tokenized_fields.any? do |field|
          field_changed?(field) ||
            instance_variable_defined?("@original_#{field}") ||
            field_set_to_nil?(field)
        end
      end

      def all_fields_have_tokens?
        self.class.tokenized_fields.all? do |field|
          token_column = token_column_for(field)
          read_attribute(token_column).present?
        end
      end

      def fields_needing_tokenization
        fields_to_process = []

        self.class.tokenized_fields.each do |field|
          # Handle nil fields with priority
          if field_set_to_nil?(field)
            fields_to_process << field
            next
          end

          token_column = token_column_for(field)

          # Skip fields that don't need processing
          # - Unchanged existing records with token
          # - Not modified fields
          if !new_record? &&
             read_attribute(token_column).present? &&
             !field_changed?(field) &&
             !instance_variable_defined?("@original_#{field}")
            next
          end

          # Add to processing list if:
          # - New record
          # - Field changed
          # - Field has @original_ set
          # - Missing token
          fields_to_process << field
        end

        fields_to_process
      end

      def get_field_value(field)
        if instance_variable_defined?("@original_#{field}")
          instance_variable_get("@original_#{field}")
        else
          read_attribute(field.to_s)
        end
      end

      def clear_token_fields(fields_to_clear)
        return if fields_to_clear.empty?

        # Step 1: Mark fields as changed (Rails 5+ needs this)
        fields_to_clear.each do |field|
          token_column = token_column_for(field)

          # Always mark token column
          send(:attribute_will_change!, token_column) if respond_to?(:attribute_will_change!)

          # Mark original field in dual-write mode
          if self.class.dual_write_enabled
            send(:attribute_will_change!, field.to_s) if respond_to?(:attribute_will_change!)
          end
        end

        # Step 2: Update field values
        fields_to_clear.each do |field|
          field_sym = field.to_sym
          token_column = token_column_for(field_sym)

          # Set token to nil
          safe_write_attribute(token_column, nil)

          # Handle original field based on dual_write
          if self.class.dual_write_enabled
            safe_write_attribute(field.to_s, nil)
          else
            # When dual_write is off, we don't write to the original field
            # Just store nil in the instance variable
            instance_variable_set("@original_#{field_sym}", nil)
          end

          # Update cache
          field_decryption_cache[field_sym] = nil
        end

        # Step 3: Force update for Rails 5+ if needed
        if rails5_or_newer? && persisted? && !new_record?
          update_hash = {}
          fields_to_clear.each do |field|
            update_hash[token_column_for(field)] = nil
            update_hash[field.to_s] = nil if self.class.dual_write_enabled
          end

          update_columns(update_hash) unless update_hash.empty?
        end
      end

      # Helper method to check if a JSON field has changed
      def json_field_changed?(json_field)
        # Use different methods based on Rails version
        if respond_to?(:saved_change_to_attribute?)
          # Rails 5.1+ changed? API
          saved_change_to_attribute?(json_field.to_s)
        elsif respond_to?(:attribute_changed?)
          # Rails 4 and 5.0 changed? API
          attribute_changed?(json_field.to_s)
        else
          # Fallback for older Rails or non-Rails
          instance_variable_defined?("@_#{json_field}_changed") ||
            previous_changes&.key?(json_field.to_s)
        end
      end
    end
  end
end
