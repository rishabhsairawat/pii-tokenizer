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
      # Override save method to securely handle tokenized fields
      def save(*args, &block)
        return super(*args, &block) if self.class.tokenized_fields.empty?

        # Track if this is a new record
        new_record = new_record?

        # Early check to see if entity_id is already available for new records
        # If it is, we can do tokenization in a single step
        entity_id_available = false
        if new_record
          # Try to get the entity_id and see if it's present
          entity_id = self.class.entity_id_proc.call(self)
          entity_id_available = entity_id.present?
        end

        # For new records without dual_write, we need to store the values in memory
        # and prevent them from being saved to the database
        if new_record && !self.class.dual_write_enabled
          # If entity_id is available, we can process tokenization directly
          if entity_id_available
            # Get entity info needed for tokenization
            entity_type = self.class.entity_type_proc.call(self)

            # Prepare to tokenize fields that have values
            tokens_data = []
            self.class.tokenized_fields.each do |field|
              field_str = field.to_s
              value = read_attribute(field_str)

              if value.nil?
                # Clear this field in memory
                write_attribute(field_str, nil)
                # Make sure the token column is nil too
                write_attribute("#{field_str}_token", nil)
                next
              end

              # Get the PII type
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

              # Store the original value for accessor
              instance_variable_set("@original_#{field}", value)

              # Clear the field so it's not saved to database
              write_attribute(field_str, nil)
            end

            # Process tokenization if we have data
            unless tokens_data.empty?
              key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)

              # Update token columns in memory before saving
              tokens_data.each do |token_data|
                field = token_data[:field_name]
                key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"

                next unless key_to_token.key?(key)

                token = key_to_token[key]
                token_column = "#{field}_token"

                # Set the token in memory
                write_attribute(token_column, token)

                # Store in decryption cache
                field_decryption_cache[field.to_sym] = token_data[:value]
              end
            end

            # Now save with the tokenized values (single DB operation)
            result = super(*args, &block)
            result
          else
            # Store original values in memory before clearing them from the record
            original_values = {}
            self.class.tokenized_fields.each do |field|
              field_str = field.to_s
              original_values[field] = read_attribute(field_str)
              # Clear the attribute so it's not included in SQL insert
              write_attribute(field_str, nil)
            end

            # Let ActiveRecord handle the initial save (without sensitive data)
            result = super(*args, &block)
            return false unless result

            # After save, restore the original values in memory for tokenization
            original_values.each do |field, value|
              instance_variable_set("@original_#{field}", value)
            end

            # Now handle tokenization with the in-memory values
            handle_tokenization(new_record)
            true
          end
        elsif new_record || self.class.dual_write_enabled
          # For new records with dual_write or existing records with dual_write:
          # Let ActiveRecord handle the save normally

          # Cache any tokenized fields that were set to nil to ensure proper handling
          nil_fields = {}

          # Track if we have any field changes that require tokenization
          needs_secondary_tokenization = false

          self.class.tokenized_fields.each do |field|
            field_str = field.to_s

            if instance_variable_defined?("@#{field}_set_to_nil") &&
               instance_variable_get("@#{field}_set_to_nil")
              nil_fields[field] = true
            elsif !new_record && changes.key?(field_str)
              # For existing records with dual_write, if field is changed but not nil,
              # check if we need tokenization after the main transaction
              # In dual_write mode, if using the field setter, the token will be updated in the main transaction
              # So we only need secondary tokenization for direct attribute assignments
              unless instance_variable_defined?("@original_#{field}")
                needs_secondary_tokenization = true
              end
            end
          end

          result = super(*args, &block)
          return false unless result

          # Check if we should skip tokenization (used by find_or_create_by)
          skip_tokenization = instance_variable_defined?(:@_skip_tokenization_callbacks) &&
                              instance_variable_get(:@_skip_tokenization_callbacks)

          # Check if the entity_id is already available and tokens were included in the initial insert
          tokens_already_processed = false
          if new_record && entity_id_available
            # Check if token columns are already set
            tokens_already_processed = self.class.tokenized_fields.all? do |field|
              field_str = field.to_s
              token_column = "#{field_str}_token"
              # Check if token column was set during insert
              # OR original field is nil (meaning no tokenization needed)
              token_value = read_attribute(token_column)
              field_value = read_attribute(field_str)
              token_value.present? || field_value.nil?
            end
          end

          # Only process additional tokenization if needed and not explicitly skipped
          # and tokens weren't already processed during insert
          if !skip_tokenization && !tokens_already_processed && (new_record && !entity_id_available || needs_secondary_tokenization)
            # After save, handle tokenization
            handle_tokenization(new_record, nil_fields)
          end

          # Clear the skip flag after use
          remove_instance_variable(:@_skip_tokenization_callbacks) if instance_variable_defined?(:@_skip_tokenization_callbacks)

          true
        else
          # For updates to existing records without dual_write:
          # We need to optimize how we handle tokenized fields in SQL

          # First check if we're just setting fields to nil, which should be a direct update
          nil_fields_update = {}
          has_only_nil_changes = true

          self.class.tokenized_fields.each do |field|
            field_str = field.to_s

            # Check if this field was set to nil via our setter
            if instance_variable_defined?("@#{field}_set_to_nil") &&
               instance_variable_get("@#{field}_set_to_nil")
              # We can directly update token column to nil
              token_column = "#{field}_token"
              nil_fields_update[token_column] = nil
            # If the field changed to a non-nil value, we need the complex path
            elsif changes.key?(field_str) && !changes[field_str][1].nil?
              has_only_nil_changes = false
              break
            end
          end

          # If we're only setting fields to nil, we can do a direct update
          if has_only_nil_changes && nil_fields_update.any?
            # Do a standard ActiveRecord save that will include our nil updates
            result = super(*args, &block)
            return false unless result

            # Clear the nil flags after saving
            self.class.tokenized_fields.each do |field|
              if instance_variable_defined?("@#{field}_set_to_nil")
                field_decryption_cache[field.to_sym] = nil
                remove_instance_variable("@#{field}_set_to_nil")
              end
            end

            return true
          end

          # For non-nil changes, we'll use an optimized approach
          # Store current tokenized values for tokenization
          tokenized_values = collect_tokenized_values

          # Skip the empty transaction if we only have tokenized field changes
          only_tokenized_changes = true
          changes.each_key do |field|
            unless self.class.tokenized_fields.include?(field.to_sym)
              only_tokenized_changes = false
              break
            end
          end

          if only_tokenized_changes && tokenized_values.any?
            # Process tokenization directly without an empty transaction
            entity_type = self.class.entity_type_proc.call(self)
            entity_id = self.class.entity_id_proc.call(self)

            if entity_id.present?
              # Prepare token data for encryption
              tokens_data = []
              updates = {}

              tokenized_values.each do |field, value|
                next if value.nil? || (value.respond_to?(:blank?) && value.blank?)

                field_str = field.to_s
                pii_type = self.class.pii_types[field_str]
                next if pii_type.blank?

                tokens_data << {
                  value: value,
                  entity_id: entity_id,
                  entity_type: entity_type,
                  field_name: field_str,
                  pii_type: pii_type
                }
              end

              # Encrypt in batch if we have data
              if tokens_data.any?
                key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)

                tokens_data.each do |token_data|
                  field = token_data[:field_name]
                  key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"

                  next unless key_to_token.key?(key)

                  token = key_to_token[key]
                  token_column = "#{field}_token"
                  updates[token_column] = token

                  # Important: Clear original field value in database since dual_write is false
                  # Only needed if the original field isn't already nil
                  field_value = read_attribute(field.to_s)
                  unless field_value.nil?
                    updates[field.to_s] = nil
                  end

                  # Store in decryption cache
                  field_decryption_cache[field.to_sym] = token_data[:value]
                end

                # Direct update without transaction
                if updates.any?
                  puts "Applying direct token updates: #{updates.inspect}" if ENV['DEBUG']
                  self.class.unscoped.where(id: id).update_all(updates)

                  # Update in-memory values
                  updates.each do |field, value|
                    write_attribute(field, value)
                  end

                  # Now also make sure to set original fields to nil in memory
                  # This ensures consistency between database and memory
                  tokenized_values.each do |field, _|
                    write_attribute(field.to_s, nil) unless self.class.dual_write_enabled
                  end

                  # No need to reload since we've manually updated the attributes
                  return true
                end
              end
            end
          end

          # For mixed changes (tokenized + non-tokenized fields),
          # or when entity_id is not available, use the standard approach

          # Reset changed tokenized fields to their original values
          reset_tokenized_fields_to_original

          # Let ActiveRecord save non-tokenized fields
          result = super(*args, &block)
          return false unless result

          # Now handle tokenization separately
          handle_tokenization_for_update(tokenized_values)
          true
        end
      end

      # Override save! to use our custom save with exception handling
      def save!(*args, &block)
        result = save(*args, &block)
        raise ActiveRecord::RecordNotSaved.new('Failed to save the record', self) unless result

        result
      end

      # Decrypt a single tokenized field
      def decrypt_field(field)
        field_sym = field.to_sym
        return nil unless self.class.tokenized_fields.include?(field_sym)

        # If this field is flagged to be set to nil, return nil without decrypting
        if instance_variable_defined?("@#{field}_set_to_nil") &&
           instance_variable_get("@#{field}_set_to_nil")
          return nil
        end

        # Check cache first
        if field_decryption_cache.key?(field_sym)
          return field_decryption_cache[field_sym]
        end

        # Get the encrypted value
        token_column = "#{field}_token"
        encrypted_value = self.class.read_from_token_column ?
                          read_attribute(token_column) :
                          read_attribute(field)

        # Try original field if token column is empty/nil
        if encrypted_value.nil? || encrypted_value.empty?
          encrypted_value = read_attribute(field)
        end

        # Return nil for nil/blank values
        return nil if encrypted_value.nil? || encrypted_value.empty?

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
          token_column = "#{field}_token"

          # Get the encrypted value
          encrypted_value = if self.class.read_from_token_column && respond_to?(token_column) && self[token_column].present?
                              self[token_column]
                            else
                              read_attribute(field)
                            end

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

      # Register this record for lazy decryption when fields are accessed
      def register_for_decryption
        return if self.class.tokenized_fields.empty? || new_record?

        # Clear any cached decrypted values for this record
        clear_decryption_cache
      end

      private

      # Compatibility method
      def token_column_for(field)
        "#{field}_token"
      end

      # Handle the tokenization process after saving
      def handle_tokenization(new_record, nil_fields = {})
        return unless persisted?

        # Get entity info
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)
        return if entity_id.blank?

        # Check for associated records that may already have tokens
        is_associated_record = respond_to?(:association_cache) &&
                               association_cache.values.any? do |assoc|
                                 assoc.is_a?(ActiveRecord::Associations::HasManyAssociation) &&
                                   assoc.owner.persisted? &&
                                   !assoc.owner.new_record?
                               end

        # Only check for redundant tokenization for new or associated records that might already have tokens
        if new_record || is_associated_record
          tokens_already_processed = self.class.tokenized_fields.all? do |field|
            field_str = field.to_s
            token_column = "#{field_str}_token"

            # Skip this check for fields that have changed or have instance variables
            next false if changes.key?(field_str)
            next false if instance_variable_defined?("@original_#{field}")

            # If the field has a value that needs tokenization, check if token exists
            value = instance_variable_defined?("@original_#{field}") ?
                   instance_variable_get("@original_#{field}") :
                   read_attribute(field)

            # Field has a token already OR field is nil (no token needed)
            token_present = read_attribute(token_column).present?
            field_nil = value.nil?

            token_present || field_nil
          end

          # If all token columns are already set, we can skip this process
          if tokens_already_processed
            puts "Skipping handle_tokenization for #{self.class.name} - tokens already processed in initial insert" if ENV['DEBUG']
            return
          end
        end

        # Determine which fields need tokenization
        fields_to_tokenize = []
        fields_to_clear = []

        # Debug output
        puts "New record: #{new_record}, Changes: #{changes.inspect}" if ENV['DEBUG']

        if new_record
          # For new records, tokenize all non-nil fields
          self.class.tokenized_fields.each do |field|
            value = instance_variable_defined?("@original_#{field}") ?
                    instance_variable_get("@original_#{field}") :
                    read_attribute(field)
            if value.nil?
              fields_to_clear << field
              puts "New record field #{field} is nil, will clear token" if ENV['DEBUG']
            else
              fields_to_tokenize << field
              puts "New record field #{field} has value '#{value}', will tokenize" if ENV['DEBUG']
            end
          end
        else
          # For updates, check various ways to determine if a field was set to nil
          self.class.tokenized_fields.each do |field|
            field_str = field.to_s

            # Skip fields that were already handled in the main transaction
            if nil_fields && nil_fields[field]
              puts "Field #{field} already handled in main transaction, skipping" if ENV['DEBUG']
              next
            end

            # First check if the field is in the changed attributes
            if changes.key?(field_str)
              old_value, new_value = changes[field_str]
              puts "Field #{field} changed from '#{old_value}' to '#{new_value}'" if ENV['DEBUG']

              if new_value.nil?
                fields_to_clear << field
                puts "Field #{field} set to nil in changes, will clear token" if ENV['DEBUG']
              else
                fields_to_tokenize << field
                puts "Field #{field} set to '#{new_value}' in changes, will tokenize" if ENV['DEBUG']
              end
            # Check for our explicit nil flag
            elsif instance_variable_defined?("@#{field}_set_to_nil") && instance_variable_get("@#{field}_set_to_nil")
              fields_to_clear << field
              puts "Field #{field} flagged as set to nil, will clear token" if ENV['DEBUG']
            # If not in changes, check if the instance variable indicates a change
            elsif instance_variable_defined?("@original_#{field}")
              value = instance_variable_get("@original_#{field}")

              if value.nil?
                fields_to_clear << field
                puts "Field #{field} set to nil via instance variable, will clear token" if ENV['DEBUG']
              else
                fields_to_tokenize << field
                puts "Field #{field} set to '#{value}' via instance variable, will tokenize" if ENV['DEBUG']
              end
            end
          end
        end

        # Now process tokenization
        updates = {}

        # Clear token columns for nil fields
        fields_to_clear.each do |field|
          token_column = "#{field}_token"

          # Skip fields that were explicitly set to nil using our setter
          # as those are already handled in the main transaction
          if nil_fields && nil_fields[field]
            puts "Field #{field} was already handled in main transaction, skipping" if ENV['DEBUG']

            # Just clear our nil flag and make sure cache is updated
            field_decryption_cache[field.to_sym] = nil
            remove_instance_variable("@#{field}_set_to_nil") if instance_variable_defined?("@#{field}_set_to_nil")
            next
          end

          # Skip fields that were explicitly set to nil using our setter
          # as those are already handled in the main transaction
          if instance_variable_defined?("@#{field}_set_to_nil") &&
             instance_variable_get("@#{field}_set_to_nil")
            puts "Field #{field} was set to nil using setter, token already cleared in main transaction" if ENV['DEBUG']

            # Just clear our nil flag and make sure cache is updated
            field_decryption_cache[field.to_sym] = nil
            remove_instance_variable("@#{field}_set_to_nil")
            next
          end

          # If this token column was already cleared in the main update,
          # we can skip the update to avoid duplicate queries
          if !new_record && read_attribute(token_column).nil?
            puts "Token column #{token_column} already nil, skipping update" if ENV['DEBUG']
            next
          end

          # Build update hash - always include token column
          field_updates = { token_column => nil }

          # If dual-write is enabled, also clear the original field
          if self.class.dual_write_enabled
            field_updates[field.to_s] = nil
            puts "Dual write enabled, also setting #{field} to nil" if ENV['DEBUG']
          end

          # Add to the batch updates
          updates.merge!(field_updates)

          # Cache the nil value to ensure accessors return nil
          field_decryption_cache[field.to_sym] = nil

          # Clear our nil flag after using it
          if instance_variable_defined?("@#{field}_set_to_nil")
            remove_instance_variable("@#{field}_set_to_nil")
          end
        end

        # Tokenize fields that need tokenization
        unless fields_to_tokenize.empty?
          tokens_data = []

          fields_to_tokenize.each do |field|
            # First check if original value is in instance variable
            value = if instance_variable_defined?("@original_#{field}")
                      instance_variable_get("@original_#{field}")
                    else
                      read_attribute(field)
                    end

            next if value.nil? || (value.respond_to?(:blank?) && value.blank?)

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

          # Encrypt in batch
          if tokens_data.any?
            key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)

            tokens_data.each do |token_data|
              field = token_data[:field_name]
              key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"

              next unless key_to_token.key?(key)

              token = key_to_token[key]
              token_column = "#{field}_token"
              updates[token_column] = token

              puts "Setting #{token_column} to #{token}" if ENV['DEBUG']

              # Store in decryption cache
              field_decryption_cache[field.to_sym] = token_data[:value]
            end
          end
        end

        # Apply updates if any
        if updates.any?
          puts "Applying updates: #{updates.inspect}" if ENV['DEBUG']

          # Skip callbacks to avoid recursion
          self.class.unscoped.where(id: id).update_all(updates)

          # Update in-memory attributes
          updates.each do |field, value|
            write_attribute(field, value)
          end

          # Only reload if not in a test context with mocked ID
          begin
            puts 'Reloading record after updates' if ENV['DEBUG']
            reload
          rescue ActiveRecord::RecordNotFound
            # Skip reload if record not found (test context)
            puts 'Record not found, skipping reload' if ENV['DEBUG']
          end
        end
      end

      # Handle tokenization for updates to existing records
      def handle_tokenization_for_update(tokenized_values)
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)
        return if entity_id.blank?

        # Skip this method entirely if there are no values to tokenize
        return if tokenized_values.empty?

        # Only check for redundant tokenization in new records or associated records
        # For regular updates (when changing values), we always need to update the tokens
        is_new_or_associated = new_record? ||
                               (respond_to?(:association_cache) &&
                                association_cache.values.any? do |assoc|
                                  assoc.is_a?(ActiveRecord::Associations::HasManyAssociation) &&
                                                                         assoc.owner.persisted? &&
                                                                         !assoc.owner.new_record?
                                end)

        # For associated records only, check if tokens are already processed
        if is_new_or_associated
          tokens_already_processed = tokenized_values.keys.all? do |field|
            field_str = field.to_s
            token_column = "#{field_str}_token"
            value = tokenized_values[field]

            # Skip this check for fields that have changed
            next false if changes.key?(field_str)

            # Field has a token already OR field is nil (no token needed)
            token_present = read_attribute(token_column).present?
            field_nil = value.nil?

            token_present || field_nil
          end

          # If tokens are already processed, skip the update
          if tokens_already_processed
            puts "Skipping handle_tokenization_for_update for #{self.class.name} - tokens already processed in initial insert" if ENV['DEBUG']
            return
          end
        end

        updates = {}
        tokens_data = []

        puts "Changes: #{changes.inspect}, Tokenized values: #{tokenized_values.inspect}" if ENV['DEBUG']
        puts "Instance variables: #{instance_variables.select { |v| v.to_s.start_with?('@original_') || v.to_s.include?('_set_to_nil') }.inspect}" if ENV['DEBUG']

        # Process fields that were explicitly set to nil or changed
        self.class.tokenized_fields.each do |field|
          field_str = field.to_s

          # Check for nil values in changes
          if changes.key?(field_str) && changes[field_str][1].nil?
            # Field was set to nil in changes - clear the token column
            token_column = "#{field_str}_token"

            # If token column is already nil, skip the update
            if read_attribute(token_column).nil?
              puts "Token column #{token_column} already nil, skipping update" if ENV['DEBUG']
              next
            end

            # Build update hash - always include token column
            field_updates = { token_column => nil }

            # If dual-write is enabled, also clear the original field
            if self.class.dual_write_enabled
              field_updates[field_str] = nil
              puts "Dual write enabled, also setting #{field} to nil" if ENV['DEBUG']
            end

            # Add to the batch updates
            updates.merge!(field_updates)

            # Also cache the nil value
            field_decryption_cache[field.to_sym] = nil
          # Check for our explicit nil flag
          elsif instance_variable_defined?("@#{field}_set_to_nil") && instance_variable_get("@#{field}_set_to_nil")
            # Field was flagged as set to nil - clear the token column
            token_column = "#{field_str}_token"

            # Skip the update if we already handled it in the main transaction via our setter
            puts "Field #{field} was set to nil using setter, token already cleared in main transaction" if ENV['DEBUG']

            # Just update cache and clear the flag
            field_decryption_cache[field.to_sym] = nil
            remove_instance_variable("@#{field}_set_to_nil")

            # Skip the update
            next
          # Check for nil values in instance variables
          elsif instance_variable_defined?("@original_#{field}") && instance_variable_get("@original_#{field}").nil?
            # Field was set to nil via instance variable - clear the token column
            token_column = "#{field_str}_token"

            # If token column is already nil, skip the update
            if read_attribute(token_column).nil?
              puts "Token column #{token_column} already nil, skipping update" if ENV['DEBUG']
              next
            end

            # Build update hash - always include token column
            field_updates = { token_column => nil }

            # If dual-write is enabled, also clear the original field
            if self.class.dual_write_enabled
              field_updates[field_str] = nil
              puts "Dual write enabled, also setting #{field} to nil" if ENV['DEBUG']
            end

            # Add to the batch updates
            updates.merge!(field_updates)

            # Also cache the nil value
            field_decryption_cache[field.to_sym] = nil
          # Check for non-nil values from tokenized_values
          elsif tokenized_values.key?(field)
            # Field was changed - tokenize it
            value = tokenized_values[field]
            next if value.nil? || (value.respond_to?(:blank?) && value.blank?)

            pii_type = self.class.pii_types[field_str]
            next if pii_type.blank?

            tokens_data << {
              value: value,
              entity_id: entity_id,
              entity_type: entity_type,
              field_name: field_str,
              pii_type: pii_type
            }

            puts "Field #{field} changed to '#{value}', will tokenize" if ENV['DEBUG']
          end
        end

        # Encrypt in batch
        if tokens_data.any?
          key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)

          tokens_data.each do |token_data|
            field = token_data[:field_name]
            key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"

            next unless key_to_token.key?(key)

            token = key_to_token[key]
            token_column = "#{field}_token"
            updates[token_column] = token
            puts "Setting #{token_column} to #{token}" if ENV['DEBUG']

            # Store in decryption cache
            field_decryption_cache[field.to_sym] = token_data[:value]
          end
        end

        # Apply updates if any
        if updates.any?
          puts "Applying updates: #{updates.inspect}" if ENV['DEBUG']

          # Update database directly to skip callbacks
          self.class.unscoped.where(id: id).update_all(updates)

          # Update in-memory token values
          updates.each do |field, value|
            write_attribute(field, value)
          end

          # Restore in-memory attributes to match what we want
          tokenized_values.each do |field, value|
            write_attribute(field.to_s, value)
          end

          # Reload to ensure consistency
          begin
            puts 'Reloading record after updates' if ENV['DEBUG']
            reload
          rescue ActiveRecord::RecordNotFound
            # Skip reload if record not found (test context)
            puts 'Record not found, skipping reload' if ENV['DEBUG']
          end
        end
      end

      # Collect current values of tokenized fields
      def collect_tokenized_values
        values = {}

        self.class.tokenized_fields.each do |field|
          field_str = field.to_s

          # Only collect values that have changed
          if changes.key?(field_str)
            values[field] = read_attribute(field_str)
          end
        end

        values
      end

      # Reset tokenized fields to their original values to prevent ActiveRecord from including them in SQL
      def reset_tokenized_fields_to_original
        self.class.tokenized_fields.each do |field|
          field_str = field.to_s

          next unless changes.key?(field_str)

          original_value = changes[field_str].first
          write_attribute(field_str, original_value)
          # Clear the change tracking
          changes_applied if respond_to?(:changes_applied)
        end
      end

      # For test compatibility - collect data for tokenization
      def collect_tokens_data(entity_type, entity_id)
        tokens_data = []
        fields_set_to_nil = []

        # Gather data for each tokenized field
        self.class.tokenized_fields.each do |field|
          # For new records, we want to always process the fields even if they haven't changed
          # For existing records, skip if the field value hasn't changed
          next unless new_record? || changes.key?(field.to_s)

          # Get the value to encrypt (try instance var first, then attribute)
          value = instance_variable_defined?("@original_#{field}") ?
                  instance_variable_get("@original_#{field}") :
                  read_attribute(field)

          # Check if the field was explicitly set to nil
          field_explicitly_set_to_nil = changes.key?(field.to_s) && changes[field.to_s][1].nil?

          if field_explicitly_set_to_nil
            fields_set_to_nil << field.to_s
            next
          end

          # Skip nil values for tokenization
          next if value.nil?
          # Skip empty values
          next if value.respond_to?(:blank?) && value.blank?

          # Get the PII type for this field
          pii_type = self.class.pii_types[field.to_s]
          next if pii_type.blank?

          # Prepare data for encryption
          tokens_data << {
            value: value,
            entity_id: entity_id,
            entity_type: entity_type,
            field_name: field.to_s,
            pii_type: pii_type
          }
        end

        # Return both regular tokens data and fields set to nil
        [tokens_data, fields_set_to_nil]
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
            if instance_variable_defined?("@#{field}_set_to_nil") &&
               instance_variable_get("@#{field}_set_to_nil")
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
              token_column = "#{field}_token"
              if respond_to?(token_column) && read_attribute(token_column).present?
                return decrypt_field(field)
              end
            end

            # Otherwise, return the plaintext value
            read_attribute(field)
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
              token_column = "#{field}_token"

              # Mark columns as changed so ActiveRecord includes them in the UPDATE
              # Only mark the token column for change in dual_write=false mode
              # In dual_write=true mode, mark both columns
              if self.class.dual_write_enabled
                # In dual_write mode, we want to update both columns in one transaction
                write_attribute(field, nil) # Explicitly write nil to the original field
                send(:attribute_will_change!, field.to_s)

                # Set the attribute to nil via super
                super(nil)
              else
                # In dual_write=false mode, we only want to update the token column
                # Don't call super(nil) as it would mark the original field for update

                # Store nil in the instance variable
                instance_variable_set("@original_#{field}", nil)
              end

              # Always mark the token column for update
              send(:attribute_will_change!, token_column)

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
            super(value)
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
        # Override find_or_initialize_by to handle tokenized fields
        def find_or_initialize_by(attributes)
          # First try to find the record
          record = find_record_by_attributes(attributes)

          # If found, return it
          return record if record

          # If not found, initialize a new one with the attributes
          record = new(attributes)

          # Make sure we set instance variables for tokenized fields
          attributes.each do |key, value|
            key_sym = key.to_sym
            if tokenized_fields.include?(key_sym)
              record.instance_variable_set("@original_#{key}", value)
            end
          end

          record
        end

        # Override find_or_create_by to handle tokenized fields
        def find_or_create_by(attributes)
          # First try to find the record
          record = find_record_by_attributes(attributes)

          # If found, return it
          return record if record

          # If not found, create a new one with the attributes
          transaction(requires_new: true) do
            # Create a new instance with attributes but don't save yet
            record = new(attributes)

            # Save to get an ID and trigger tokenization
            result = record.save

            # Run any validation block if provided
            yield(record) if block_given?

            unless result
              # If save fails, return the record with errors
              raise ActiveRecord::Rollback
            end
          end

          record
        end

        private

        # Find a record matching the given attributes
        def find_record_by_attributes(attributes)
          if read_from_token_column
            # Process tokenized fields for searching
            tokenized_attrs = {}
            standard_attrs = {}

            attributes.each do |key, value|
              key_sym = key.to_sym
              if tokenized_fields.include?(key_sym) && value.present?
                # Use token column for search
                tokens = PiiTokenizer.encryption_service.search_tokens(value)
                if tokens.empty?
                  # Return nil if no matching tokens
                  return nil
                end

                token_column = "#{key_sym}_token"
                tokenized_attrs[token_column] = tokens
              else
                standard_attrs[key] = value
              end
            end

            # First find by tokenized fields if any
            if tokenized_attrs.any?
              # Directly search using the token column
              token_column = tokenized_attrs.keys.first
              tokens = tokenized_attrs.values.first
              record = where(token_column => tokens).first
              return record if record
            else
              # Just use standard where method if no tokenized fields
              record = where(attributes).first
              return record if record
            end
          else
            # Just use standard where method if not reading from token columns
            record = where(attributes).first
            return record if record
          end

          nil
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

      # Set up callbacks - intentionally minimal
      before_save :encrypt_pii_fields

      # Define encrypt_pii_fields method
      define_method(:encrypt_pii_fields) do
        # Skip if no tokenized fields or if callbacks are disabled
        return if self.class.tokenized_fields.empty?
        return if instance_variable_defined?(:@_skip_tokenization_callbacks) &&
                  instance_variable_get(:@_skip_tokenization_callbacks)

        # Get entity information
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)

        # For new records without ID, delay tokenization until after save
        return if entity_id.blank?

        # Check if tokenization has already been processed for this record
        # For new records, check if token columns already have values
        if new_record?
          tokens_already_processed = self.class.tokenized_fields.all? do |field|
            field_str = field.to_s
            token_column = "#{field_str}_token"
            # Check if token column already has a value OR the field is nil
            token_present = read_attribute(token_column).present?
            field_nil = read_attribute(field_str).nil?

            # If we have a token or field is nil (no need for token), consider it processed
            token_present || field_nil
          end

          # Skip further processing if all tokens are already set
          if tokens_already_processed
            puts "Skipping encrypt_pii_fields for #{self.class.name} - tokens already processed in initial insert" if ENV['DEBUG']
            return
          end
        end

        # Get fields that need tokenization
        tokens_data = []
        fields_set_to_nil = []

        self.class.tokenized_fields.each do |field|
          field_str = field.to_s

          # Check for force token update flag
          force_update = instance_variable_defined?("@force_token_update_for_#{field}") &&
                         instance_variable_get("@force_token_update_for_#{field}")

          # Only process fields that have changed or need forced update
          next unless new_record? || changes.key?(field_str) || force_update

          value = read_attribute(field)

          # Handle nil values
          if value.nil?
            fields_set_to_nil << field_str
            next
          end

          # Skip blank values
          next if value.respond_to?(:blank?) && value.blank?

          # Get PII type
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

        # Handle fields set to nil
        fields_set_to_nil.each do |field|
          token_column = "#{field}_token"

          # Clear the force update flag if it exists
          if instance_variable_defined?("@force_token_update_for_#{field}")
            remove_instance_variable("@force_token_update_for_#{field}")
          end

          # For in-memory handling, always update the token column
          write_attribute(token_column, nil)

          # If dual-write is enabled, ensure original field remains nil
          # This will be included in the main ActiveRecord UPDATE
          if self.class.dual_write_enabled
            write_attribute(field, nil)
          end
        end

        # Skip if no data to encrypt
        return if tokens_data.empty?

        # Perform batch encryption
        key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)

        # Update model with encrypted values
        tokens_data.each do |token_data|
          field = token_data[:field_name]
          key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:value]}"

          next unless key_to_token.key?(key)

          token = key_to_token[key]
          token_column = "#{field}_token"

          # Write token to token column
          write_attribute(token_column, token)

          # Clear original field if not dual-writing
          write_attribute(field, nil) unless self.class.dual_write_enabled

          # Cache decrypted value
          field_decryption_cache[field.to_sym] = token_data[:value]
        end
      end

      # Add callback
      after_find :register_for_decryption
      after_initialize :register_for_decryption
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
