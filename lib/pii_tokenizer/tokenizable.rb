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

    included do
      # Rails 5 uses class_attribute with default option, but Rails 4 doesn't support it
      # Using compatible approach for both Rails 4 and 5
      class_attribute :tokenized_fields
      self.tokenized_fields = []

      class_attribute :entity_type_proc
      class_attribute :entity_id_proc

      # Store pii_types for each field
      class_attribute :pii_types
      self.pii_types = {}

      # Store dual-write configuration
      class_attribute :dual_write_enabled
      self.dual_write_enabled = false

      # Store which column to read from (original or token)
      class_attribute :read_from_token_column
      self.read_from_token_column = false

      # Cache for decrypted values - using class instance variable instead of thread_mattr_accessor
      class_attribute :_decryption_cache
      self._decryption_cache = {}

      # Define class methods for cache access
      class << self
        # Get the current decryption cache
        # @return [Hash] The decryption cache for all instances
        def decryption_cache
          _decryption_cache
        end

        # Set the decryption cache
        # @param value [Hash] The new decryption cache value
        def decryption_cache=(value)
          self._decryption_cache = value
        end
      end

      # Define callbacks to encrypt/decrypt fields
      before_save :encrypt_pii_fields
      after_find :register_for_decryption
      after_initialize :register_for_decryption
    end

    class_methods do
      # Configure tokenization for this model
      #
      # @param fields [Array<Symbol>, Hash] Fields to tokenize, either as array or mapping of fields to PII types
      # @param entity_type [String, Proc] Type of entity (customer, employee, etc)
      # @param entity_id [Proc] Lambda to extract entity ID from record
      # @param dual_write [Boolean] Whether to write to both original and token columns
      #        When true, both the original column and the token column will contain values
      #        When false, only the token column will have values, original column will be nil
      # @param read_from_token [Boolean] Whether to read from token columns
      #        When true, values will be read from token columns if they exist
      #        When false, values will always be read from original columns
      # @return [void]
      # @example With array of fields
      #   tokenize_pii fields: [:first_name, :last_name],
      #               entity_type: 'customer',
      #               entity_id: ->(record) { "user_#{record.id}" }
      # @example With custom PII types
      #   tokenize_pii fields: {first_name: 'NAME', email: 'EMAIL_ADDRESS'},
      #               entity_type: ->(record) { record.role || 'customer' },
      #               entity_id: ->(record) { "#{record.role}_#{record.id}" }
      def tokenize_pii(fields:, entity_type:, entity_id:, dual_write: true, read_from_token: false)
        # Convert to string keys for consistency
        fields_hash = {}

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

        # Define the attribute readers and writers that auto-encrypt/decrypt
        tokenized_fields.each do |field|
          field_sym = field.to_sym
          define_field_reader(field_sym)
          define_field_writer(field_sym)
        end
      end

      # Override writer method to store original value
      # @param field [Symbol] Field to define writer for
      # @return [void]
      def define_field_writer(field)
        define_method("#{field}=") do |value|
          # Store the unencrypted value in the object, will be encrypted on save
          instance_variable_set("@original_#{field}", value)
          # Also need to set the attribute for the record to be dirty
          super(value)
        end
      end

      # Override reader method to decrypt on access
      # @param field [Symbol] Field to define reader for
      # @return [void]
      def define_field_reader(field)
        define_method(field) do
          # If we have an original value set (from a write), return that
          if instance_variable_defined?("@original_#{field}")
            return instance_variable_get("@original_#{field}")
          end

          # Check if we have a cached decrypted value
          if field_decryption_cache.key?(field)
            return field_decryption_cache[field]
          end

          # If we should read from token column, decrypt
          if read_from_token_column
            token_column = "#{field}_token"
            if respond_to?(token_column) && read_attribute(token_column).present?
              return decrypt_field(field)
            end
          end

          # Otherwise, return the plaintext value
          read_attribute(field)
        end
      end

      # Get the token column name for a field
      # @param field [Symbol, String] The field name
      # @return [String] Token column name (field_token)
      def token_column_for(field)
        "#{field}_token"
      end

      # Preload decrypted values for a collection of records
      # This enables batch decryption of the same fields across multiple records
      # @param records [Array<ActiveRecord>] Records to preload
      # @param fields [Array<Symbol>] Fields to decrypt
      # @return [void]
      # @example Preload names for a collection
      #   User.preload_decrypted_fields(users, :first_name, :last_name)
      def preload_decrypted_fields(records, *fields)
        fields = fields.flatten.map(&:to_sym)
        fields_to_decrypt = fields & tokenized_fields
        return if fields_to_decrypt.empty? || records.empty?

        # Collect all tokens that need decryption
        tokens_to_decrypt = []
        record_token_map = {}

        records.each do |record|
          fields_to_decrypt.each do |field|
            token_column = token_column_for(field)
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
      # @param fields [Array<Symbol>] Fields to decrypt
      # @return [ActiveRecord::Relation] The relation for method chaining
      # @example Include decrypted fields in a query
      #   users = User.where(active: true).include_decrypted_fields(:first_name, :last_name)
      def include_decrypted_fields(*fields)
        fields = fields.flatten.map(&:to_sym)

        # Store the fields to decrypt in the relation's context
        all.extending(DecryptedFieldsExtension).decrypt_fields(fields)
      end
    end

    # Extension module for the ActiveRecord::Relation to support decryption in batches
    module DecryptedFieldsExtension
      # Set fields to decrypt when relation is loaded
      # @param fields [Array<Symbol>] Fields to decrypt
      # @return [ActiveRecord::Relation] self for chaining
      def decrypt_fields(fields)
        @decrypt_fields = fields
        self
      end

      # Override to_a to preload decrypted fields
      # @return [Array<ActiveRecord>] Array of records with decrypted fields
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

    # Get the entity type for this record
    # @return [String] Entity type
    def entity_type
      self.class.entity_type_proc.call(self)
    end

    # Get the entity ID for this record
    # @return [String] Entity ID
    def entity_id
      self.class.entity_id_proc.call(self)
    end

    # Get the pii_type for a field
    # @param field [Symbol, String] Field name
    # @return [String, nil] PII type or nil if not found
    def pii_type_for(field)
      self.class.pii_types[field.to_s]
    end

    # Get the token column name for a field
    # @param field [Symbol, String] Field name
    # @return [String] Token column name
    def token_column_for(field)
      self.class.token_column_for(field)
    end

    # Encrypt all tokenized fields before saving
    # Called by the before_save callback
    # @return [void]
    def encrypt_pii_fields
      # Skip if no tokenized fields
      return if self.class.tokenized_fields.empty?

      # Get entity information
      entity_type = self.class.entity_type_proc.call(self)
      entity_id = self.class.entity_id_proc.call(self)

      # Skip if no entity ID (for new records)
      return if entity_id.blank?

      # Prepare data for batch encryption
      tokens_data = []

      # Gather data for each tokenized field
      self.class.tokenized_fields.each do |field|
        # Skip if the field value hasn't changed
        next unless new_record? || changes.key?(field.to_s)

        # Get the value to encrypt (try instance var first, then attribute)
        value = instance_variable_defined?("@original_#{field}") ?
                instance_variable_get("@original_#{field}") :
                read_attribute(field)

        # Skip nil values
        next if value.nil?
        # Skip empty values
        next if value.respond_to?(:blank?) && value.blank?

        # Get the PII type for this field
        pii_type = self.class.pii_types[field.to_s]
        next if pii_type.blank?

        # Prepare data for encryption - support for both new and legacy formats
        tokens_data << {
          value: value,
          entity_id: entity_id,
          entity_type: entity_type,
          field_name: field.to_s,
          pii_type: pii_type
        }
      end

      # Skip if no data to encrypt
      return if tokens_data.empty?

      # Perform batch encryption
      key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)

      # Update model with encrypted values
      tokens_data.each do |token_data|
        field = token_data[:field_name].to_sym
        key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}"

        # Get the encrypted token for this field
        next unless key_to_token.key?(key)

        token = key_to_token[key]

        # Write to the token column if it exists
        token_column = token_column_for(field)
        if respond_to?(token_column)
          write_attribute(token_column, token)
        end

        # Clear the original column if not dual writing
        write_attribute(field, nil) unless self.class.dual_write_enabled

        # Store decrypted value in cache
        field_decryption_cache[field] = token_data[:value]
      end
    end

    # Register this record for lazy decryption when fields are accessed
    # Called by after_find and after_initialize callbacks
    # @return [void]
    def register_for_decryption
      return if self.class.tokenized_fields.empty? || new_record?

      # Clear any cached decrypted values for this record
      clear_decryption_cache
    end

    # Decrypt a single tokenized field
    # @param field [Symbol, String] the field to decrypt
    # @return [String, nil] the decrypted value, or nil if the field is not tokenized or has no value
    # @example Decrypt a single field
    #   user.decrypt_field(:email)
    def decrypt_field(field)
      field_sym = field.to_sym
      return nil unless self.class.tokenized_fields.include?(field_sym)

      # Check cache first
      if defined?(@field_decryption_cache) && @field_decryption_cache.is_a?(Hash) && @field_decryption_cache.key?(field_sym)
        return @field_decryption_cache[field_sym]
      end

      # Initialize field_decryption_cache if needed
      @field_decryption_cache ||= {}

      # Direct access to instance variables to avoid getter method recursion
      token_column = "#{field}_token"

      # Get the encrypted value directly from attributes hash if available
      # or use read_attribute which avoids getter methods
      encrypted_value = nil

      if self.class.read_from_token_column
        encrypted_value = read_attribute(token_column)
      end

      # Try original field if token column is empty/nil
      if encrypted_value.nil? || (encrypted_value.respond_to?(:empty?) && encrypted_value.empty?)
        encrypted_value = read_attribute(field)
      end

      # Return nil for nil/blank values
      return nil if encrypted_value.nil? || (encrypted_value.respond_to?(:empty?) && encrypted_value.empty?)

      # Decrypt the value
      result = PiiTokenizer.encryption_service.decrypt_batch([encrypted_value])
      decrypted_value = result[encrypted_value] || read_attribute(field)

      # Cache the decrypted value
      @field_decryption_cache[field_sym] = decrypted_value

      decrypted_value
    end

    # Decrypt multiple tokenized fields at once
    # @param fields [Array<Symbol, String>] the fields to decrypt
    # @return [Hash] mapping of field names to decrypted values
    # @example Decrypt multiple fields
    #   user.decrypt_fields(:first_name, :last_name, :email)
    def decrypt_fields(*fields)
      fields = fields.flatten.map(&:to_sym)
      fields_to_decrypt = fields & self.class.tokenized_fields
      return {} if fields_to_decrypt.empty?

      # Map field names to encrypted values
      field_to_encrypted = {}
      encrypted_values = []

      fields_to_decrypt.each do |field|
        # Get token column name
        token_column = token_column_for(field)

        # Get the encrypted value
        encrypted_value = if self.class.read_from_token_column && respond_to?(token_column) && self[token_column].present?
                            self[token_column]
                          else
                            # Fallback to original column for backward compatibility
                            read_attribute(field)
                          end

        next if encrypted_value.blank?

        # Map field -> encrypted value for later use
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

    # Get the field decryption cache for this instance
    # @return [Hash] Cache of decrypted field values
    def field_decryption_cache
      @field_decryption_cache ||= {}
    end

    private

    # Token column name for a field
    # @param field [Symbol, String] Field name
    # @return [String] Token column name
    def token_column_for(field)
      "#{field}_token"
    end

    # Clear the per-instance decryption cache
    # @return [void]
    def clear_decryption_cache
      @field_decryption_cache = {}
    end

    # Cache a decrypted value for a field
    # @param field [Symbol, String] Field name
    # @param value [String, nil] Decrypted value
    # @return [void]
    def cache_decrypted_value(field, value)
      self.class.decryption_cache[object_id] ||= {}
      self.class.decryption_cache[object_id][field.to_sym] = value
    end

    # Get a cached decrypted value for a field
    # @param field [Symbol, String] Field name
    # @return [String, nil] Cached value or nil if not cached
    def get_cached_decrypted_value(field)
      return nil unless self.class.decryption_cache[object_id]

      self.class.decryption_cache[object_id][field.to_sym]
    end
  end
end
