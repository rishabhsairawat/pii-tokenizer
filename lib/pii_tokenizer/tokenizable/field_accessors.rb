require 'active_support/concern'

module PiiTokenizer
  module Tokenizable
    module FieldAccessors
      extend ActiveSupport::Concern

      included do
        include VersionCompatibility
      end

      class_methods do
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

            # Get the token column value
            token_column = token_column_for(field)
            token_value = read_attribute(token_column)

            # Get the original field value
            field_value = read_attribute(field.to_s)

            # Decide which value to use based on settings
            if self.class.read_from_token_column && !token_value.nil?
              # When reading from token is enabled and we have a token (including empty string), decrypt it
              decrypted = decrypt_field(field)
              return decrypted
            elsif !self.class.read_from_token_column && field_value.present?
              # When not reading from token and original field has data, use that
              return field_value
            else
              # Last resort: return the original field value (might be nil)
              return field_value
            end
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
              if self.class.dual_write_enabled
                # In dual_write mode, we want to update both columns in one transaction
                send(:attribute_will_change!, field.to_s) if respond_to?(:attribute_will_change!)
                safe_write_attribute(field, nil) # Explicitly write nil to the original field
              else
                # In dual_write=false mode, we only want to update the token column
                # and not mark the original field for update
                instance_variable_set("@original_#{field}", nil)
              end

              # Always mark the token column for update in both Rails 4 and 5
              send(:attribute_will_change!, token_column) if respond_to?(:attribute_will_change!)

              # Set the token column to nil immediately in memory
              safe_write_attribute(token_column, nil)

              # Store nil in the decryption cache to avoid unnecessary decrypt calls
              field_decryption_cache[field.to_sym] = nil

              return nil
            end

            # For non-nil values, continue with normal flow
            # Store the unencrypted value in the object
            instance_variable_set("@original_#{field}", value)

            # Also need to set the attribute for the record to be dirty
            if self.class.dual_write_enabled
              # In dual-write mode, mark the original field for update and set its value
              send(:attribute_will_change!, field.to_s) if respond_to?(:attribute_will_change!)
              safe_write_attribute(field, value)
            else
              # In non-dual-write mode, only store the original value and mark token column
              # Do not attempt to write to the original field
              instance_variable_set("@original_#{field}", value)
            end

            # Mark the token column as changed for both dual_write modes
            send(:attribute_will_change!, "#{field}_token") if respond_to?(:attribute_will_change!)

            # Cache the value
            field_decryption_cache[field.to_sym] = value

            # Return the value
            value
          end
        end
      end
    end
  end
end
