require 'active_support/concern'

module PiiTokenizer
  # Main module providing PII tokenization capabilities to ActiveRecord models
  # When included in a model, this module adds methods to encrypt/decrypt PII fields
  # and manage token values through an external encryption service
  #
  # @example Basic usage
  #   class User < ActiveRecord::Base
  #     include PiiTokenizer::Tokenizable
  #
  #     tokenize_pii fields: [:first_name, :last_name, :email],
  #                 entity_type: 'customer',
  #                 entity_id: ->(user) { "user_#{user.id}" }
  #   end
  #
  # @note Each tokenized field should have a corresponding _token column in the database
  #       (e.g., first_name should have first_name_token column)
  module Tokenizable
    extend ActiveSupport::Concern

    # Module containing the primary instance methods
    module InstanceMethods
      # Decrypt a single tokenized field
      def decrypt_field(field)
        field_sym = field.to_sym
        return nil unless self.class.tokenized_fields.include?(field_sym)

        # If this field is flagged to be set to nil, return nil without decrypting
        return nil if field_set_to_nil?(field_sym)

        # Check cache first
        return field_decryption_cache[field_sym] if field_decryption_cache.key?(field_sym)

        # Get the encrypted value
        token_column = token_column_for(field)
        encrypted_value = get_encrypted_value(field_sym, token_column)

        # Return nil for nil/blank values
        return nil if encrypted_value.blank?

        # Decrypt the value
        result = PiiTokenizer.encryption_service.decrypt_batch([encrypted_value])
        decrypted_value = result[encrypted_value] || read_attribute(field)

        # Cache the decrypted value
        field_decryption_cache[field_sym] = decrypted_value

        decrypted_value
      end

      # Decrypt multiple tokenized fields at once
      def decrypt_fields(*fields)
        fields = fields.flatten.map(&:to_sym)
        fields_to_decrypt = fields & self.class.tokenized_fields
        return {} if fields_to_decrypt.empty?

        # Map field names to encrypted values
        field_to_encrypted = {}
        encrypted_values = []

        fields_to_decrypt.each do |field|
          token_column = token_column_for(field)

          # Get the encrypted value
          encrypted_value = get_encrypted_value(field, token_column)
          next if encrypted_value.blank?

          field_to_encrypted[field] = encrypted_value
          encrypted_values << encrypted_value
        end

        return {} if encrypted_values.empty?

        # Decrypt all values in a batch
        decrypted_values = PiiTokenizer.encryption_service.decrypt_batch(encrypted_values)

        # Map field names to decrypted values
        result = {}
        field_to_encrypted.each do |field, encrypted|
          decrypted = decrypted_values[encrypted]
          if decrypted
            result[field] = decrypted
            field_decryption_cache[field] = decrypted
          else
            # Fallback to original value if decryption fails
            result[field] = read_attribute(field)
          end
        end

        result
      end

      # Get the decryption cache for this instance
      def field_decryption_cache
        @field_decryption_cache ||= {}
      end

      # Get the entity type for this record
      def entity_type
        self.class.entity_type_proc.call(self)
      end

      # Get the entity ID for this record
      def entity_id
        self.class.entity_id_proc.call(self)
      end

      # Various backwards compatibility methods

      # Clear the per-instance decryption cache
      def clear_decryption_cache
        @field_decryption_cache = {}
      end

      # Cache a decrypted value for a field
      def cache_decrypted_value(field, value)
        field_decryption_cache[field.to_sym] = value
      end

      # Get a cached decrypted value for a field
      def get_cached_decrypted_value(field)
        field_decryption_cache[field.to_sym]
      end

      # Register this record for decryption when fields are accessed
      def register_for_decryption
        return if self.class.tokenized_fields.empty? || new_record?

        # Clear any cached decrypted values for this record
        clear_decryption_cache
      end

      # Primary callback method for encrypting PII fields
      def encrypt_pii_fields
        # Skip if no tokenized fields
        return if self.class.tokenized_fields.empty?
        
        # Get entity information
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)

        puts("** before_save ** Entity Id is: #{entity_id}")
        # For new records without ID, delay tokenization until after save
        return if entity_id.blank?

        puts("** before_save ** New Record?: #{new_record?}")
        # Early return for persisted records with no changes to tokenized fields
        if !new_record?
          # Check if any tokenized fields have changes
          has_field_changes = has_tokenized_field_changes?
          
          # Check if all fields already have tokens
          all_have_tokens = all_fields_have_tokens?
          
          # If nothing has changed and all tokens exist, skip tokenization completely
          if !has_field_changes && all_have_tokens
            return
          end
        end

        # Find fields that need tokenization
        fields_to_process = fields_needing_tokenization

        # Skip if no fields need tokenization
        return if fields_to_process.empty?
        
        # Process tokenization for identified fields
        process_tokenization(fields_to_process)
        
        # IMPORTANT: For new records, we need to make sure tokens will be persisted
        # even if the after_save callback somehow doesn't run
        # This defensive code addresses potential issues in production environments
        if new_record? && persisted?
          # Store tokens that need to be saved after the transaction is committed
          @_tokens_to_persist = {}
          
          self.class.tokenized_fields.each do |field|
            field_str = field.to_s
            token_column = "#{field_str}_token"
            
            # Capture the token value to persist
            token_value = read_attribute(token_column)
            if token_value.present?
              @_tokens_to_persist[token_column] = token_value
              
              # For dual_write=false, also clear the original field
              if !self.class.dual_write_enabled
                @_tokens_to_persist[field_str] = nil
              end
            end
          end
          
          # Set up an after_commit hook to ensure tokens are saved
          # This is a one-time hook for this specific record
          after_commit_method = lambda do
            if @_tokens_to_persist && @_tokens_to_persist.any?
              begin
                # Use update_all to persist tokens without callbacks
                self.class.unscoped.where(id: id).update_all(@_tokens_to_persist)
              rescue => e
                # Silently handle errors to avoid breaking the application
                if defined?(Rails) && Rails.respond_to?(:logger)
                  Rails.logger.error("PiiTokenizer: Failed to persist tokens in after_commit hook: #{e.message}")
                end
              ensure
                # Clear the stored tokens
                @_tokens_to_persist = nil
              end
            end
          end
          
          # Use ActiveRecord's after_commit callback if available
          if respond_to?(:after_commit)
            after_commit(on: :create, &after_commit_method)
          end
          
          # As an additional fallback, schedule the update on the next tick
          # This is only needed in very unusual configurations
          # where the callbacks might be skipped
          if defined?(Thread) && Thread.respond_to?(:new)
            Thread.new do
              begin
                sleep(0.1) # Brief delay to let the transaction complete
                after_commit_method.call if @_tokens_to_persist && @_tokens_to_persist.any?
              rescue => e
                # Silently handle errors in background thread
              end
            end
          end
        end
      end

      private
      
      # Check if a field is flagged to be set to nil
      def field_set_to_nil?(field)
        field_var = "@#{field}_set_to_nil"
        instance_variable_defined?(field_var) && instance_variable_get(field_var)
      end
      
      # Check if any tokenized fields have changes
      def has_tokenized_field_changes?
        self.class.tokenized_fields.any? do |field|
          field_str = field.to_s
          changes.key?(field_str) || 
          instance_variable_defined?("@original_#{field}") ||
          field_set_to_nil?(field)
        end
      end
      
      # Check if all tokenized fields have token values
      def all_fields_have_tokens?
        self.class.tokenized_fields.all? do |field|
          token_column = token_column_for(field)
          read_attribute(token_column).present?
        end
      end
      
      # Get the encrypted value for a field
      def get_encrypted_value(field, token_column)
        if self.class.read_from_token_column && respond_to?(token_column) && self[token_column].present?
          self[token_column]
        else
          read_attribute(field)
        end
      end
      
      # Determine which fields need tokenization
      def fields_needing_tokenization
        fields_to_process = []
        
        self.class.tokenized_fields.each do |field|
          field_str = field.to_s
          token_column = token_column_for(field)
          
          # For existing records, skip fields that already have tokens and haven't been modified
          if !new_record? && !changes.key?(field_str) && 
             !instance_variable_defined?("@original_#{field}") && 
             !field_set_to_nil?(field) &&
             read_attribute(token_column).present?
            # Field already has a token and hasn't changed
            next
          end
          
          # Check if the field has been modified
          field_is_new = new_record?
          field_in_changes = changes.key?(field_str)
          field_has_original = instance_variable_defined?("@original_#{field}")
          field_set_to_nil = field_set_to_nil?(field)
          
          field_modified = field_is_new || field_in_changes || field_has_original || field_set_to_nil
          
          # Only process fields that need tokenization
          if field_modified
            # Get the current value (from instance var or attribute)
            value = if instance_variable_defined?("@original_#{field}")
                      instance_variable_get("@original_#{field}")
                    else
                      read_attribute(field_str)
                    end
            
            # Add field to be processed regardless of value
            # (nil handling happens in process_tokenization)
            fields_to_process << field
          end
        end
        
        fields_to_process
      end

      # Get token column name for a field
      def token_column_for(field)
        "#{field}_token"
      end

      # Process tokenization for the specified fields
      def process_tokenization(fields_to_process = nil)
        # If no specific fields are provided, use all tokenized fields
        fields_to_process ||= self.class.tokenized_fields
        
        # Convert to array of symbols for consistency
        fields_to_process = Array(fields_to_process).map(&:to_sym)
        
        # Skip if no fields to process
        return if fields_to_process.empty?
        
        # Get entity information
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)
        
        # For new records without ID, delay tokenization until after save
        return if entity_id.blank?

        # Collect data for tokenization
        tokens_data = []
        fields_to_clear = []

        fields_to_process.each do |field|
          field_str = field.to_s
          token_column = token_column_for(field)
          
          # Skip fields that already have tokens and haven't been explicitly marked for processing
          if !new_record? && 
             !changes.key?(field_str) && 
             !instance_variable_defined?("@original_#{field}") && 
             !field_set_to_nil?(field) &&
             read_attribute(token_column).present?
            next
          end
          
          # Get the value from memory
          value = get_field_value(field)
          
          # Check if field was explicitly set to nil
          if field_set_to_nil?(field)
            fields_to_clear << field
            next
          end
          
          # Special handling for nil values
          if value.nil?
            # If field is nil, clear the token
            fields_to_clear << field
            next
          end
          
          # Skip blank values
          next if value.respond_to?(:blank?) && value.blank?
          
          # Get PII type for this field
          pii_type = self.class.pii_types[field_str]
          next if pii_type.blank?
          
          # Add to tokenization batch
          tokens_data << {
            value: value,
            entity_id: entity_id,
            entity_type: entity_type,
            field_name: field_str,
            pii_type: pii_type
          }
        end
        
        # Handle fields to clear
        clear_token_fields(fields_to_clear)
        
        # Skip if no data to encrypt
        return if tokens_data.empty?
        
        # Encrypt in batch
        key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)
        
        # Update model with encrypted values
        update_model_with_tokens(tokens_data, key_to_token)
      end
      
      # Get value for a field from instance variable or attribute
      def get_field_value(field)
        if instance_variable_defined?("@original_#{field}")
          instance_variable_get("@original_#{field}")
        else
          read_attribute(field.to_s)
        end
      end
      
      # Clear token fields when value is nil
      def clear_token_fields(fields_to_clear)
        fields_to_clear.each do |field|
          token_column = token_column_for(field)
          write_attribute(token_column, nil)
          
          # If dual-write is enabled, also clear the original field 
          if self.class.dual_write_enabled
            write_attribute(field.to_s, nil)
          end
          
          # Cache the nil value
          field_decryption_cache[field.to_sym] = nil
        end
      end
      
      # Update model attributes with token values
      def update_model_with_tokens(tokens_data, key_to_token)
        Rails.logger.info("PiiTokenizer: update_model_with_tokens called with #{tokens_data.size} tokens") if defined?(Rails) && Rails.respond_to?(:logger)
        
        # Log the keys in the key_to_token hash for debugging
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger.debug?
          Rails.logger.debug("PiiTokenizer: key_to_token keys: #{key_to_token.keys.inspect}")
        end
        
        tokens_data.each do |token_data|
          field = token_data[:field_name]
          key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"
          
          # Debug logging for key generation
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.info("PiiTokenizer: Generated key: '#{key}'")
            Rails.logger.info("PiiTokenizer: Key exists in key_to_token? #{key_to_token.key?(key)}")
            
            # Add extensive debug logging if key doesn't exist
            unless key_to_token.key?(key)
              Rails.logger.warn("PiiTokenizer: Key not found in key_to_token for field #{field}")
              debug_key_format(token_data, key_to_token)
            end
          end
          
          next unless key_to_token.key?(key)
          
          token = key_to_token[key]
          token_column = token_column_for(field)
          
          # Write token to token column
          write_attribute(token_column, token)
          
          # In dual-write mode, preserve the original field value
          if self.class.dual_write_enabled
            write_attribute(field, token_data[:value])
          else
            # In non-dual-write mode, clear the original field
            write_attribute(field, nil)
          end
          
          # Cache decrypted value 
          field_decryption_cache[field.to_sym] = token_data[:value]
        end
      end

      # Process tokenization after saving a new record
      def process_after_save_tokenization
        if defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.info("PiiTokenizer: process_after_save_tokenization called for #{self.class.name} ##{id}")
        end
        
        puts("** after_save ** persisted? #{persisted?}")
        return unless persisted?
        return if self.class.tokenized_fields.empty?
        
        # Get entity info
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)
        puts("** after_save ** Entity Id is: #{entity_id}")
        
        # Log entity info
        if defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.info("PiiTokenizer: entity_type=#{entity_type}, entity_id=#{entity_id}")
        end
        
        # Skip if entity_id is still blank after save (unlikely but possible)
        return if entity_id.blank?

        # Only process after_save for new records 
        puts("** after_save ** respond_to?(:previous_changes): #{respond_to?(:previous_changes)}")
        puts("** after_save ** previous_changes: #{previous_changes}") 
        is_new_record = respond_to?(:previous_changes) && previous_changes.key?('id')

        puts("** after_save ** respond_to?(:changed_attributes): #{respond_to?(:changed_attributes)}")
        puts("** after_save ** changed_attributes: #{changed_attributes}") 
        is_new_record ||= respond_to?(:changed_attributes) && changed_attributes.key?('id')
        
        if defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.info("PiiTokenizer: Is new record? #{is_new_record}")
        end
        
        return unless is_new_record
        
        # Debug: analyze all tokenized fields to see why they might not be processed
        if defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.info("PiiTokenizer: Analyzing #{self.class.tokenized_fields.size} tokenized fields")
          
          self.class.tokenized_fields.each do |field|
            field_str = field.to_s
            token_column = "#{field_str}_token"
            
            # Get current values
            value = get_field_value(field)
            token = read_attribute(token_column)
            pii_type = self.class.pii_types[field_str]
            
            Rails.logger.info("PiiTokenizer: Field #{field_str}")
            Rails.logger.info("  - Value: #{value.inspect}")
            Rails.logger.info("  - Token: #{token.inspect}")
            Rails.logger.info("  - PII Type: #{pii_type.inspect}")
            Rails.logger.info("  - Value blank? #{value.blank?}")
            Rails.logger.info("  - Token present? #{token.present?}")
          end
        end
        
        # For new records, we should always update the database to ensure token values are persisted
        # The changes might already exist in memory from the before_save callback
        # but they need to be written to the database through update_all
        
        # Collect data for tokenization
        tokens_data = []
        db_updates = {}

        self.class.tokenized_fields.each do |field|
          field_str = field.to_s
          token_column = "#{field_str}_token"
          
          # Get value and skip if blank
          value = get_field_value(field)
          
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.info("PiiTokenizer: Processing field #{field_str}, value=#{value.inspect}")
          end
          
          next if value.blank?
          
          # Get token - either from memory or get a new one
          token = read_attribute(token_column)
          
          if token.present?
            # Token already exists in memory (from before_save callback)
            # Just add it to database updates
            db_updates[token_column] = token
            
            if defined?(Rails) && Rails.respond_to?(:logger)
              Rails.logger.info("PiiTokenizer: Token already exists for #{field_str}: #{token}")
            end
            
            # In dual_write=false mode, also clear the original field in DB
            if !self.class.dual_write_enabled
              db_updates[field_str] = nil
            end
          else
            # No token yet, need to encrypt the value
            # Get PII type for this field
            pii_type = self.class.pii_types[field_str]
            
            if pii_type.blank?
              if defined?(Rails) && Rails.respond_to?(:logger)
                Rails.logger.warn("PiiTokenizer: No PII type found for field #{field_str}, skipping")
              end
              next
            end
            
            # Add to tokenization batch
            tokens_data << {
              value: value,
              entity_id: entity_id,
              entity_type: entity_type,
              field_name: field_str,
              pii_type: pii_type
            }
            
            if defined?(Rails) && Rails.respond_to?(:logger)
              Rails.logger.info("PiiTokenizer: Adding to tokenization batch: field=#{field_str}, entity_id=#{entity_id}")
            end
          end
        end
        
        # Check if we have any tokens to process
        if defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.info("PiiTokenizer: tokens_data.size=#{tokens_data.size}")
          if tokens_data.empty?
            Rails.logger.warn("PiiTokenizer: No tokens to process! Check earlier logs for why fields were skipped.")
          end
        end
        
        # Process any fields that still need encryption
        if tokens_data.any?
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.info("PiiTokenizer: Encrypting batch of #{tokens_data.size} tokens")
            Rails.logger.info("PiiTokenizer: tokens_data: #{tokens_data.inspect}")
          end
          
          begin
            # Encrypt in batch
            key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)
            
            # Log the returned keys for debugging
            if defined?(Rails) && Rails.respond_to?(:logger)
              Rails.logger.info("PiiTokenizer: encrypt_batch returned #{key_to_token.size} tokens")
              Rails.logger.info("PiiTokenizer: key_to_token: #{key_to_token.inspect}")
            end
            
            # Process encrypted values
            tokens_data.each do |token_data|
              field = token_data[:field_name]
              key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"
              
              # Debug logging for key generation and matching
              if defined?(Rails) && Rails.respond_to?(:logger)
                Rails.logger.info("PiiTokenizer: Generated key for #{field}: '#{key}'")
                Rails.logger.info("PiiTokenizer: Key exists in key_to_token? #{key_to_token.key?(key)}")
                
                # Try alternative key format
                alt_key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:field_name]}"
                Rails.logger.info("PiiTokenizer: Alternative key: '#{alt_key}'")
                Rails.logger.info("PiiTokenizer: Alt key exists? #{key_to_token.key?(alt_key)}")
                
                # Show all keys in response
                Rails.logger.info("PiiTokenizer: All keys in response: #{key_to_token.keys.inspect}")
              end
              
              # First try the standard key format
              if key_to_token.key?(key)
                token = key_to_token[key]
                token_column = "#{field}_token"
                
                # Write token to token column in memory
                write_attribute(token_column, token)
                
                # Add to updates for database
                db_updates[token_column] = token
                
                if defined?(Rails) && Rails.respond_to?(:logger)
                  Rails.logger.info("PiiTokenizer: Setting token for #{field}: #{token}")
                end
                
                # If not dual_write, clear the original field in DB
                if !self.class.dual_write_enabled
                  db_updates[field] = nil
                end
                
                # Cache decrypted value
                field_decryption_cache[field.to_sym] = token_data[:value]
              else
                # Try alternative key format (field_name instead of value)
                alt_key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:field_name]}"
                
                if key_to_token.key?(alt_key)
                  token = key_to_token[alt_key]
                  token_column = "#{field}_token"
                  
                  if defined?(Rails) && Rails.respond_to?(:logger)
                    Rails.logger.info("PiiTokenizer: Found token using alternative key format for #{field}")
                  end
                  
                  # Write token to token column in memory
                  write_attribute(token_column, token)
                  
                  # Add to updates for database
                  db_updates[token_column] = token
                  
                  # If not dual_write, clear the original field in DB
                  if !self.class.dual_write_enabled
                    db_updates[field] = nil
                  end
                  
                  # Cache decrypted value
                  field_decryption_cache[field.to_sym] = token_data[:value]
                else
                  # Log failure if neither key format works
                  if defined?(Rails) && Rails.respond_to?(:logger)
                    Rails.logger.warn("PiiTokenizer: Could not find token for field #{field} with any key format")
                  end
                end
              end
            end
          rescue => e
            if defined?(Rails) && Rails.respond_to?(:logger)
              Rails.logger.error("PiiTokenizer: Error during encrypt_batch: #{e.class.name} - #{e.message}")
              Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
            end
          end
        end
        
        # Apply updates to database if any exist
        if db_updates.any?
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.info("PiiTokenizer: Updating database with #{db_updates.size} changes: #{db_updates.keys.join(', ')}")
            Rails.logger.info("PiiTokenizer: db_updates: #{db_updates.inspect}")
          end
          
          begin
            self.class.unscoped.where(id: id).update_all(db_updates)
            
            if defined?(Rails) && Rails.respond_to?(:logger)
              Rails.logger.info("PiiTokenizer: Database update completed successfully")
            end
          rescue => e
            if defined?(Rails) && Rails.respond_to?(:logger)
              Rails.logger.error("PiiTokenizer: Error during database update: #{e.class.name} - #{e.message}")
              Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
            end
          end
        else
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.warn("PiiTokenizer: No updates to apply to database for #{self.class.name} ##{id}")
          end
        end
      end

      # Update the database with tokens after save
      def update_after_save(tokens_data, key_to_token)
        if defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.info("PiiTokenizer: update_after_save called with #{tokens_data.size} tokens")
          Rails.logger.debug("PiiTokenizer: key_to_token keys: #{key_to_token.keys.inspect}") if Rails.logger.debug?
        end
        
        updates = {}
        
        tokens_data.each do |token_data|
          field = token_data[:field_name]
          key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"
          
          # Debug logging for key generation and matching
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.info("PiiTokenizer: Generated key for #{field}: '#{key}'")
            Rails.logger.info("PiiTokenizer: Key exists in key_to_token? #{key_to_token.key?(key)}")
            
            # Add extensive debug logging if key doesn't exist
            unless key_to_token.key?(key)
              Rails.logger.warn("PiiTokenizer: Key not found in key_to_token for field #{field}")
              debug_key_format(token_data, key_to_token)
            end
          end
          
          next unless key_to_token.key?(key)
          
          token = key_to_token[key]
          token_column = "#{field}_token"
          
          # Write token to token column in memory
          write_attribute(token_column, token)
          
          # Add to updates for database
          updates[token_column] = token
          
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.info("PiiTokenizer: Setting token for #{field}: #{token}")
          end
          
          # If not dual_write, clear the original field, otherwise preserve it
          if !self.class.dual_write_enabled
            updates[field] = nil
            write_attribute(field, nil)
          else
            # In dual_write, preserve original value unless already changed
            write_attribute(field, token_data[:value])
          end
          
          # Cache decrypted value
          field_decryption_cache[field.to_sym] = token_data[:value]
        end
        
        # Apply updates if any
        if updates.any?
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.info("PiiTokenizer: Updating database with #{updates.size} changes: #{updates.keys.join(', ')}")
          end
          self.class.unscoped.where(id: id).update_all(updates)
        else
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.warn("PiiTokenizer: No updates to apply to database")
          end
        end
      end

      # Helper method to debug key format issues
      def debug_key_format(token_data, key_to_token)
        return unless defined?(Rails) && Rails.respond_to?(:logger)
        
        # Generate the key based on current implementation
        current_key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"
        
        # Try various alternative key formats
        alternatives = {
          "using field_name instead of value" => 
            "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:field_name]}",
          "using string pii_field instead of value" => 
            "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data['pii_field']}",
          "using underscore after entity_type" => 
            "#{token_data[:entity_type].upcase}_:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}",
          "entity_type lowercase" => 
            "#{token_data[:entity_type]}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"
        }
        
        # Log current key format and if it exists
        Rails.logger.warn("PiiTokenizer: Debug key formats for missing key. token_data: #{token_data.inspect}")
        Rails.logger.warn("  Current implementation key: '#{current_key}', exists? #{key_to_token.key?(current_key)}")
        
        # Log each alternative format and if it exists in the key_to_token hash
        alternatives.each do |description, alt_key|
          Rails.logger.warn("  #{description}: '#{alt_key}', exists? #{key_to_token.key?(alt_key)}")
        end
        
        # Check if any key contains portions of our data
        matching_keys = key_to_token.keys.select do |k| 
          k.include?(token_data[:entity_id].to_s) || 
          k.include?(token_data[:value].to_s) || 
          k.include?(token_data[:field_name].to_s)
        end
        
        if matching_keys.any?
          Rails.logger.warn("  Found potentially related keys:")
          matching_keys.each do |k|
            Rails.logger.warn("    '#{k}'")
          end
        else
          Rails.logger.warn("  No similar keys found in returned hash")
        end
        
        # Dump the first few keys from the response for inspection
        sample_keys = key_to_token.keys.first(3)
        Rails.logger.warn("  Sample keys from response: #{sample_keys.inspect}")
      end
    end

    # Module containing field reader/writer methods
    module FieldAccessors
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Define field accessors for tokenized fields
        def define_field_accessors
          tokenized_fields.each do |field|
            define_field_reader(field)
            define_field_writer(field)
          end
        end

        private

        # Define reader method that transparently decrypts
        def define_field_reader(field)
          define_method(field) do
            # If the field is flagged to be set to nil, return nil without decrypting
            if field_set_to_nil?(field)
              return nil
            end

            # If we have an original value set (from a write), return that
            if instance_variable_defined?("@original_#{field}")
              return instance_variable_get("@original_#{field}")
            end

            # Check if we have a cached decrypted value
            if field_decryption_cache.key?(field)
              return field_decryption_cache[field]
            end

            # If we should read from token column, decrypt
            if self.class.read_from_token_column
              token_column = token_column_for(field)
              if respond_to?(token_column) && read_attribute(token_column).present?
                return decrypt_field(field)
              end
            end

            # Otherwise, return the plaintext value
            value = read_attribute(field)
            
            # If we don't have a plaintext value but we have a token, try to decrypt it
            if value.nil? && !self.class.read_from_token_column
              token_column = token_column_for(field)
              if respond_to?(token_column) && read_attribute(token_column).present?
                return decrypt_field(field)
              end
            end
            
            value
          end
        end

        # Define writer method that tracks original value
        def define_field_writer(field)
          define_method("#{field}=") do |value|
            # Check if setting to nil
            if value.nil?
              # Store a flag indicating this field was explicitly set to nil
              instance_variable_set("@#{field}_set_to_nil", true)

              # Force this field to be marked as changed
              token_column = token_column_for(field)

              # Mark columns as changed so ActiveRecord includes them in the UPDATE
              # Only mark the token column for change in dual_write=false mode
              # In dual_write=true mode, mark both columns
              if self.class.dual_write_enabled
                # In dual_write mode, we want to update both columns in one transaction
                write_attribute(field, nil) # Explicitly write nil to the original field
                send(:attribute_will_change!, field.to_s) if respond_to?(:attribute_will_change!)

                # Set the attribute to nil via super
                super(nil)
              else
                # In dual_write=false mode, we only want to update the token column
                # Don't call super(nil) as it would mark the original field for update

                # Store nil in the instance variable
                instance_variable_set("@original_#{field}", nil)
              end

              # Always mark the token column for update
              send(:attribute_will_change!, token_column) if respond_to?(:attribute_will_change!)

              # Set the token column to nil immediately in memory
              # This ensures it will be part of the main transaction
              write_attribute(token_column, nil)

              # Store nil in the decryption cache to avoid unnecessary decrypt calls
              field_decryption_cache[field.to_sym] = nil

              return nil
            end

            # For non-nil values, continue with normal flow
            # Store the unencrypted value in the object
            instance_variable_set("@original_#{field}", value)

            # Also need to set the attribute for the record to be dirty
            if self.class.dual_write_enabled
              # In dual-write mode, update the original field
              super(value)
            else
              # In non-dual-write mode, don't update the original field
              # but still mark it as changed
              send(:attribute_will_change!, "#{field}_token") if respond_to?(:attribute_will_change!)
              super(value)
            end
          end
        end
      end
    end

    # Module containing class methods for searching
    module SearchMethods
      extend ActiveSupport::Concern

      class_methods do
        # Override the default ActiveRecord where method to handle tokenized fields
        def where(opts = :chain, *rest)
          # Handle :chain case for proper method chaining
          if opts == :chain
            return super
          end

          # For non-hash conditions or when tokenization is disabled, use default behavior
          unless read_from_token_column && opts.is_a?(Hash)
            return super
          end

          # Process conditions - separate tokenized fields from standard ones
          tokenized_conditions = {}
          standard_conditions = {}

          opts.each do |key, value|
            key_sym = key.to_sym

            if tokenized_fields.include?(key_sym)
              if value.nil?
                # If searching for nil value, use standard condition
                standard_conditions[key] = value
              else
                # For tokenized fields, get tokens and search by token column
                tokens = PiiTokenizer.encryption_service.search_tokens(value)

                # If no tokens found, return empty relation
                if tokens.empty?
                  return none
                end

                # Add condition to search token column for matching tokens
                token_column = "#{key_sym}_token"
                tokenized_conditions[token_column] = tokens
              end
            else
              # For non-tokenized fields, use standard condition
              standard_conditions[key] = value
            end
          end

          # Start with standard conditions
          relation = super(standard_conditions, *rest)

          # Apply tokenized conditions
          tokenized_conditions.each do |token_column, tokens|
            relation = relation.where(token_column => tokens)
          end

          relation
        end

        # Override find_by to use our custom where method
        def find_by(attributes)
          where(attributes).first
        end

        # Search for a record by a tokenized field
        def search_by_tokenized_field(field, value)
          return nil if value.nil?

          # Get the token column
          token_column = "#{field}_token"

          # Search for tokens that match the value
          tokens = PiiTokenizer.encryption_service.search_tokens(value)
          return nil if tokens.empty?

          # Find records where the token column matches any of the returned tokens
          where(token_column => tokens).first
        end

        # Search for all records matching a tokenized field value
        def search_all_by_tokenized_field(field, value)
          return [] if value.nil?

          # Get the token column
          token_column = "#{field}_token"

          # Search for tokens that match the value
          tokens = PiiTokenizer.encryption_service.search_tokens(value)
          return [] if tokens.empty?

          # Find all records where the token column matches any of the returned tokens
          where(token_column => tokens)
        end
      end
    end

    # Module containing batch operations
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

    # Module containing find_or_create methods
    module FindOrCreateMethods
      extend ActiveSupport::Concern

      class_methods do
        # Method to find by tokenized fields or create
        def find_or_create_by(attributes)
          find_by(attributes) || create(attributes)
        end

        # Method to find by tokenized fields or initialize
        def find_or_initialize_by(attributes)
          find_by(attributes) || new(attributes)
        end
      end
    end

    # Main module included in the model
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

      # Include our modules
      include InstanceMethods
      include FieldAccessors
      include SearchMethods
      include BatchOperations
      include FindOrCreateMethods

      # Set up callbacks if the class supports them
      before_save :encrypt_pii_fields if respond_to?(:before_save)
      
      # Use respond_to? to check if callbacks are supported by the class      
      after_save :process_after_save_tokenization if respond_to?(:after_save)

      if respond_to?(:after_find)
        after_find :register_for_decryption
      end
      
      if respond_to?(:after_initialize)
        after_initialize :register_for_decryption
      end
    end

    # Class methods for configuration
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
        @_decryption_cache ||= {}
      end

      # Setter for the decryption cache
      def decryption_cache=(value)
        @_decryption_cache = value
      end

      # Generate a token column name for a field
      def token_column_for(field)
        "#{field}_token"
      end

      # Handle dynamic finder methods for tokenized fields
      def method_missing(method_name, *args, &block)
        method_str = method_name.to_s

        # Match methods like find_by_email, find_by_first_name, etc.
        if method_str.start_with?('find_by_') && args.size == 1
          field_name = method_str.sub('find_by_', '')
          field_sym = field_name.to_sym

          if tokenized_fields.include?(field_sym)
            # Only use tokenized search if read_from_token is true
            if read_from_token_column
              # Explicitly use tokenized search
              return search_by_tokenized_field(field_sym, args.first)
            else
              # Otherwise, use standard find_by
              return find_by(field_sym => args.first)
            end
          end
        end

        super
      end

      # Check if we respond to a method
      def respond_to_missing?(method_name, include_private = false)
        method_str = method_name.to_s
        if method_str.start_with?('find_by_')
          field_name = method_str.sub('find_by_', '')
          return tokenized_fields.include?(field_name.to_sym)
        end

        super
      end
    end

    # Make our extension module available as a constant
    DecryptedFieldsExtension = BatchOperations::DecryptedFieldsExtension
  end
end
