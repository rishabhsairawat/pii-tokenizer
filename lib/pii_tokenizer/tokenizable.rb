require 'active_support/concern'

module PiiTokenizer
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

      # Cache for decrypted values - using class instance variable instead of thread_mattr_accessor
      class_attribute :_decryption_cache
      self._decryption_cache = {}

      # Define class methods for cache access
      class << self
        def decryption_cache
          _decryption_cache
        end

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
      # Define which fields should be tokenized
      #
      # @param fields [Array<Symbol>, Hash] list of fields to tokenize or hash mapping fields to pii_types
      # @param entity_type [String, Proc] entity type or proc that returns entity type
      # @param entity_id [Proc] proc that returns the entity ID for this record
      def tokenize_pii(fields:, entity_type:, entity_id:)
        field_pii_types = {}

        # Handle both array of fields and hash mapping fields to pii_types
        if fields.is_a?(Hash)
          field_pii_types = fields
          fields = fields.keys
        else
          # Default to uppercase field name if not specified
          fields.each do |field|
            field_pii_types[field] = field.to_s.upcase
          end
        end

        self.tokenized_fields = fields.map(&:to_sym)
        self.pii_types = field_pii_types.transform_keys(&:to_sym)

        self.entity_type_proc = if entity_type.is_a?(Proc)
                                 entity_type
                               else
                                 ->(_) { entity_type.to_s }
                               end

        self.entity_id_proc = entity_id

        # Define attribute accessors to intercept tokenized fields
        fields.each do |field|
          define_field_reader(field)
          define_field_writer(field)
        end
      end

      # Override writer method to store original value
      def define_field_writer(field)
        define_method("#{field}=") do |value|
          # Store the unencrypted value in the object, will be encrypted on save
          instance_variable_set("@original_#{field}", value)
          # Also need to set the attribute for the record to be dirty
          super(value)
        end
      end

      # Override reader method to decrypt on access
      def define_field_reader(field)
        define_method(field) do
          # If we have an original value set (from a write), return that
          if instance_variable_defined?("@original_#{field}")
            return instance_variable_get("@original_#{field}")
          end
          # Otherwise, decrypt the stored value
          decrypt_field(field)
        end
      end
    end

    # Get the entity type for this record
    def entity_type
      self.class.entity_type_proc.call(self)
    end

    # Get the entity ID for this record
    def entity_id
      self.class.entity_id_proc.call(self)
    end

    # Get the pii_type for a field
    def pii_type_for(field)
      self.class.pii_types[field.to_sym]
    end

    # Encrypt all tokenized fields before saving
    def encrypt_pii_fields
      puts "DEBUG: encrypt_pii_fields called for #{self.class.name}"
      puts "DEBUG: tokenized_fields = #{self.class.tokenized_fields.inspect}"
      
      return if self.class.tokenized_fields.empty?

      # Collect fields that need encryption
      tokens_data = []

      self.class.tokenized_fields.each do |field|
        # Get the value to encrypt (either from instance var or attribute)
        value = instance_variable_get("@original_#{field}")
        # If no original value is set, use the current attribute value
        value ||= read_attribute(field)
        
        puts "DEBUG: Processing field #{field}, original value: #{instance_variable_defined?("@original_#{field}")}, value: #{value.inspect}"
        
        next if value.blank?

        tokens_data << {
          value: value,
          entity_id: entity_id,
          entity_type: entity_type,
          field_name: field.to_s,
          pii_type: pii_type_for(field)
        }
      end

      puts "DEBUG: Collected tokens_data = #{tokens_data.inspect}"

      # Encrypt in a batch
      return if tokens_data.empty?

      encrypted_values = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)
      puts "DEBUG: Received encrypted_values = #{encrypted_values.inspect}"

      # Update the model attributes with encrypted values
      tokens_data.each do |token_data|
        field = token_data[:field_name].to_sym
        key = "#{token_data[:entity_type]}:#{token_data[:entity_id]}:#{token_data[:pii_type]}"
        
        puts "DEBUG: Looking for key = #{key} in encrypted_values"

        next unless encrypted_values.key?(key)
        
        puts "DEBUG: Found key, storing encrypted value for field #{field}"

        # Store the encrypted value in the database column
        write_attribute(field, encrypted_values[key])

        # Clear the instance variable to avoid confusion
        remove_instance_variable("@original_#{field}") if instance_variable_defined?("@original_#{field}")

        # Store decrypted value in cache for later access
        cache_decrypted_value(field, token_data[:value])
      end
    end

    # Register this record for lazy decryption when fields are accessed
    def register_for_decryption
      return if self.class.tokenized_fields.empty? || new_record?

      # Clear any cached decrypted values for this record
      clear_decryption_cache
    end

    # Decrypt a specific field
    def decrypt_field(field)
      field = field.to_sym
      return read_attribute(field) unless self.class.tokenized_fields.include?(field)

      # Return the decrypted value if already in cache
      cached = get_cached_decrypted_value(field)
      return cached if cached

      # Get the encrypted value from the database
      encrypted_value = read_attribute(field)
      return nil if encrypted_value.blank?

      # Create a batch of one for this field
      token_data = [{
        token: encrypted_value,
        entity_id: entity_id,
        entity_type: entity_type,
        field_name: field.to_s,
        pii_type: pii_type_for(field)
      }]

      # Perform decryption
      decrypted_values = PiiTokenizer.encryption_service.decrypt_batch(token_data)
      key = "#{entity_type}:#{entity_id}:#{pii_type_for(field)}"

      if decrypted_values.key?(key)
        decrypted_value = decrypted_values[key]
        cache_decrypted_value(field, decrypted_value)
        return decrypted_value
      end

      read_attribute(field)
    end

    # Decrypt multiple fields at once in a batch request
    def decrypt_fields(*fields)
      fields = fields.map(&:to_sym)
      return {} if fields.empty?

      # Filter to only include tokenized fields
      fields &= self.class.tokenized_fields

      # Collect fields that need decryption
      tokens_data = []

      fields.each do |field|
        # Skip if already decrypted and in cache
        next if get_cached_decrypted_value(field)

        # Get the encrypted value from the database
        encrypted_value = read_attribute(field)
        next if encrypted_value.blank?

        tokens_data << {
          token: encrypted_value,
          entity_id: entity_id,
          entity_type: entity_type,
          field_name: field.to_s,
          pii_type: pii_type_for(field)
        }
      end

      # Decrypt in a batch
      return {} if tokens_data.empty?

      decrypted_values = PiiTokenizer.encryption_service.decrypt_batch(tokens_data)

      # Update cache with decrypted values
      result = {}

      fields.each do |field|
        key = "#{entity_type}:#{entity_id}:#{pii_type_for(field)}"

        if decrypted_values.key?(key)
          decrypted_value = decrypted_values[key]
          cache_decrypted_value(field, decrypted_value)
          result[field] = decrypted_value
        else
          # Use cached value or database value as fallback
          result[field] = get_cached_decrypted_value(field) || read_attribute(field)
        end
      end

      result
    end

    private

    # Cache management methods
    def clear_decryption_cache
      self.class.decryption_cache[object_id] = {}
    end

    def cache_decrypted_value(field, value)
      self.class.decryption_cache[object_id] ||= {}
      self.class.decryption_cache[object_id][field.to_sym] = value
    end

    def get_cached_decrypted_value(field)
      return nil unless self.class.decryption_cache[object_id]

      self.class.decryption_cache[object_id][field.to_sym]
    end
  end
end
