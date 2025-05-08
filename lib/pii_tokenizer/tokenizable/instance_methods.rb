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
        return if self.class.tokenized_fields.empty? || new_record?

        clear_decryption_cache
      end

      def decrypt_field(field)
        field_sym = field.to_sym
        return nil unless self.class.tokenized_fields.include?(field_sym)
        return nil if field_set_to_nil?(field_sym)

        # Check cache first
        return field_decryption_cache[field_sym] if field_decryption_cache.key?(field_sym)

        # Get and decrypt value
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

      # --- Encryption Methods ---

      def encrypt_pii_fields
        # Skip if no tokenized fields or no entity ID
        return if self.class.tokenized_fields.empty?

        entity_id = self.class.entity_id_proc.call(self)
        return if entity_id.blank?

        # Initialize token tracking
        init_tokenization_state

        # Early return for unchanged persisted records
        if !new_record? && !tokenized_field_changes? && all_fields_have_tokens?
          return
        end

        # Preserve original values if dual_write is enabled
        preserve_original_values if self.class.dual_write_enabled

        # Process fields that need tokenization
        fields_to_process = fields_needing_tokenization
        return if fields_to_process.empty?

        process_tokenization(fields_to_process)

        # Restore preserved values for dual_write=true
        restore_original_values if self.class.dual_write_enabled

        # Skip post-processing for new records
        @_skip_after_save_tokenization = true if new_record?
      end

      def process_after_save_tokenization
        return unless persisted?
        return if self.class.tokenized_fields.empty?
        return if @_skip_after_save_tokenization

        # Check if new record
        is_new_record = if rails5_or_newer?
                          respond_to?(:previous_changes) && previous_changes.key?('id')
                        else
                          respond_to?(:changes) && changes.key?('id')
                        end

        return unless is_new_record
        return if all_fields_processed?

        # Get entity info
        entity_id = self.class.entity_id_proc.call(self)
        return if entity_id.blank?

        # Process remaining fields
        unprocessed_fields = get_unprocessed_fields
        return if unprocessed_fields.empty?

        process_tokenization(unprocessed_fields)
        apply_pending_updates
      end

      private

      # --- Helper Methods ---

      def init_tokenization_state
        @tokenization_state = { processed_fields: [], pending_db_updates: {} }
      end

      def get_tokenization_state
        @tokenization_state ||= { processed_fields: [], pending_db_updates: {} }
      end

      def all_fields_processed?
        @tokenization_state && @tokenization_state[:processed_fields].sort == self.class.tokenized_fields.sort
      end

      def get_unprocessed_fields
        fields = []
        self.class.tokenized_fields.each do |field|
          next if @tokenization_state && @tokenization_state[:processed_fields].include?(field)

          fields << field
        end
        fields
      end

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

      def apply_pending_updates
        if @tokenization_state && @tokenization_state[:pending_db_updates].any?
          begin
            self.class.unscoped.where(id: id).update_all(@tokenization_state[:pending_db_updates])
          rescue StandardError => e
            Rails.logger.error("PiiTokenizer: Error during database update: #{e.class.name} - #{e.message}")
          end
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

          # Skip unchanged fields that already have tokens
          if !new_record? &&
             !field_changed?(field) &&
             !instance_variable_defined?("@original_#{field}") &&
             read_attribute(token_column_for(field)).present?
            next
          end

          # Check if field needs processing
          field_modified = new_record? ||
                           field_changed?(field) ||
                           instance_variable_defined?("@original_#{field}") ||
                           field_set_to_nil?(field)

          fields_to_process << field if field_modified
        end

        fields_to_process
      end

      def process_tokenization(fields_to_process)
        fields_to_process = Array(fields_to_process).map(&:to_sym)
        return if fields_to_process.empty?

        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)
        return if entity_id.blank?

        state = get_tokenization_state
        tokens_data = []
        fields_to_clear = []

        # Categorize fields to process
        fields_to_process.each do |field|
          # Skip if already processed with token
          token_column = token_column_for(field)
          unless field_needs_processing?(field, token_column)
            next
          end

          value = get_field_value(field)

          # Handle nil values
          if field_set_to_nil?(field) || value.nil?
            fields_to_clear << field
            next
          end

          # Handle empty strings without calling encryption service
          if value.respond_to?(:blank?) && value.blank?
            token_column = token_column_for(field)
            safe_write_attribute(token_column, '')
            state[:pending_db_updates][token_column] = ''
            state[:processed_fields] << field unless state[:processed_fields].include?(field)
            next
          end

          # Skip blank values only if dual_write is disabled
          next if !self.class.dual_write_enabled && value.respond_to?(:blank?) && value.blank?

          # Prepare for tokenization
          pii_type = self.class.pii_types[field.to_s]
          next if pii_type.blank?

          tokens_data << {
            value: value,
            entity_id: entity_id,
            entity_type: entity_type,
            field_name: field.to_s,
            pii_type: pii_type
          }
        end

        # Process nil fields
        clear_token_fields(fields_to_clear) unless fields_to_clear.empty?
        return if tokens_data.empty?

        # Process tokens
        key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)
        update_model_with_tokens(tokens_data, key_to_token)

        # Update tracking
        (tokens_data.map { |d| d[:field_name].to_sym } + fields_to_clear).each do |field|
          state[:processed_fields] << field unless state[:processed_fields].include?(field)
        end
      end

      def field_needs_processing?(field, token_column)
        new_record? ||
          field_changed?(field) ||
          instance_variable_defined?("@original_#{field}") ||
          field_set_to_nil?(field) ||
          read_attribute(token_column).blank?
      end

      def clear_token_fields(fields_to_clear)
        return if fields_to_clear.empty?

        state = get_tokenization_state

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
          state[:pending_db_updates][token_column] = nil

          # Handle original field based on dual_write
          if self.class.dual_write_enabled
            safe_write_attribute(field.to_s, nil)
            state[:pending_db_updates][field.to_s] = nil
          else
            # When dual_write is off, we don't write to the original field
            # Just store nil in the instance variable
            instance_variable_set("@original_#{field_sym}", nil)
          end

          # Update cache and tracking
          field_decryption_cache[field_sym] = nil
          state[:processed_fields] << field_sym unless state[:processed_fields].include?(field_sym)
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

      def get_field_value(field)
        if instance_variable_defined?("@original_#{field}")
          instance_variable_get("@original_#{field}")
        else
          read_attribute(field.to_s)
        end
      end

      def update_model_with_tokens(tokens_data, key_to_token)
        state = get_tokenization_state

        tokens_data.each do |token_data|
          field = token_data[:field_name]
          field_sym = field.to_sym
          value = token_data[:value]

          # Generate key and get token
          entity_type = token_data[:entity_type].upcase
          entity_id = token_data[:entity_id]
          pii_type = token_data[:pii_type]

          key = "#{entity_type}:#{entity_id}:#{pii_type}:#{value}"
          token = key_to_token[key]
          next unless token

          # Update token column
          token_column = token_column_for(field_sym)
          safe_write_attribute(token_column, token)
          state[:pending_db_updates][token_column] = token

          # Handle original column based on dual_write mode
          if self.class.dual_write_enabled
            if value.present?
              safe_write_attribute(field, value)
              state[:pending_db_updates][field] = value
            else
              original_value = read_attribute(field)
              state[:pending_db_updates][field] = original_value if original_value.present?
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
        end
      end
    end
  end
end
