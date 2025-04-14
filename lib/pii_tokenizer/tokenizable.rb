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

      # Register this record for decryption when fields are accessed
      def register_for_decryption
        return if self.class.tokenized_fields.empty? || new_record?

        # Clear any cached decrypted values for this record
        clear_decryption_cache
      end

      # Primary callback method for encrypting PII fields
      def encrypt_pii_fields
        # Skip if no tokenized fields or if callbacks are disabled
        return if self.class.tokenized_fields.empty?
        return if instance_variable_defined?(:@_skip_tokenization_callbacks) &&
                  instance_variable_get(:@_skip_tokenization_callbacks)

        # Get entity information
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)

        # For new records without ID, delay tokenization until after save
        return if entity_id.blank?

        # Early return for persisted records with no changes to tokenized fields
        if !new_record?
          # Check if any tokenized fields have changes
          has_field_changes = self.class.tokenized_fields.any? do |field|
            field_str = field.to_s
            changes.key?(field_str) || 
            instance_variable_defined?("@original_#{field}") ||
            instance_variable_defined?("@#{field}_set_to_nil")
          end
          
          # Check if all fields already have tokens
          all_have_tokens = self.class.tokenized_fields.all? do |field|
            token_column = "#{field}_token"
            read_attribute(token_column).present?
          end
          
          # If nothing has changed and all tokens exist, skip tokenization completely
          if !has_field_changes && all_have_tokens
            return
          end
        end

        # Find fields that need tokenization
        fields_to_process = []

        # Check each field to see if it needs tokenization
        self.class.tokenized_fields.each do |field|
          field_str = field.to_s
          token_column = "#{field}_token"
          
          # For existing records, skip fields that already have tokens and haven't been modified
          if !new_record? && !changes.key?(field_str) && 
             !instance_variable_defined?("@original_#{field}") && 
             !instance_variable_defined?("@#{field}_set_to_nil") &&
             read_attribute(token_column).present?
            # Field already has a token and hasn't changed
            next
          end
          
          # Check if the field has been modified
          field_is_new = new_record?
          field_in_changes = changes.key?(field_str)
          field_has_original = instance_variable_defined?("@original_#{field}")
          field_set_to_nil = instance_variable_defined?("@#{field}_set_to_nil")
          
          field_modified = field_is_new || field_in_changes || field_has_original || field_set_to_nil
          
          # Only process fields that need tokenization
          if field_modified
            # Get the current value (from instance var or attribute)
            value = if instance_variable_defined?("@original_#{field}")
                      instance_variable_get("@original_#{field}")
                    else
                      read_attribute(field_str)
                    end
            
            # Skip nil values
            next if value.nil?
            
            # Skip blank values
            next if value.respond_to?(:blank?) && value.blank?
            
            # This field needs tokenization
            fields_to_process << field
          end
        end
        
        # Skip if no fields need tokenization
        return if fields_to_process.empty?
        
        # Process tokenization for identified fields
        process_tokenization(fields_to_process)
      end

      private

      # Compatibility method
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
          token_column = "#{field}_token"
          
          # Skip fields that already have tokens and haven't been explicitly marked for processing
          if !new_record? && 
             !changes.key?(field_str) && 
             !instance_variable_defined?("@original_#{field}") && 
             !instance_variable_defined?("@#{field}_set_to_nil") &&
             read_attribute(token_column).present?
            next
          end
          
          # Get the value from memory
          value = nil
          
          # First check if original value is in instance variable
          if instance_variable_defined?("@original_#{field}")
            value = instance_variable_get("@original_#{field}")
          else
            # Otherwise, use the current value
            value = read_attribute(field)
          end
          
          # Check if field was explicitly set to nil
          if instance_variable_defined?("@#{field}_set_to_nil") && 
             instance_variable_get("@#{field}_set_to_nil")
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
        fields_to_clear.each do |field|
          token_column = "#{field}_token"
          write_attribute(token_column, nil)
          
          # If dual-write is enabled, also clear the original field
          if self.class.dual_write_enabled
            write_attribute(field.to_s, nil)
          end
          
          # Cache the nil value
          field_decryption_cache[field.to_sym] = nil
        end
        
        # Skip if no data to encrypt
        return if tokens_data.empty?
        
        # Encrypt in batch
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
      
      # Process tokenization after saving a new record
      def process_after_save_tokenization
        return unless persisted?
        return if self.class.tokenized_fields.empty?
        
        # Get entity info
        entity_type = self.class.entity_type_proc.call(self)
        entity_id = self.class.entity_id_proc.call(self)
        return if entity_id.blank?
        
        # Only process after_save for new records 
        return unless respond_to?(:previous_changes) && previous_changes.key?('id')
        
        # Check for tokenized fields that still need processing
        needs_tokenization = self.class.tokenized_fields.any? do |field|
          field_str = field.to_s
          token_column = "#{field_str}_token"
          
          # Check if field needs tokenization
          value = instance_variable_defined?("@original_#{field}") ? 
                 instance_variable_get("@original_#{field}") : 
                 read_attribute(field)
                 
          # Field needs tokenization if it has a value and no token
          value.present? && read_attribute(token_column).blank?
        end
        
        return unless needs_tokenization
        
        # Process tokenization
        process_tokenization
        
        # Update the database directly to bypass callbacks
        updates = {}
        
        self.class.tokenized_fields.each do |field|
          field_str = field.to_s
          token_column = "#{field_str}_token"
          token_value = read_attribute(token_column)
          
          # Only include fields that have tokens
          next if token_value.blank?
          
          updates[token_column] = token_value
          updates[field_str] = nil unless self.class.dual_write_enabled
        end
        
        # Apply updates if any
        if updates.any?
          self.class.unscoped.where(id: id).update_all(updates)
        end
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
      if respond_to?(:after_save)
        after_save :process_after_save_tokenization
      end
      
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
