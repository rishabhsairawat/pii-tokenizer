require 'active_support/concern'

module PiiTokenizer
  module Tokenizable
    extend ActiveSupport::Concern

    included do
      class_attribute :tokenized_fields, default: []
      class_attribute :entity_type_proc
      class_attribute :entity_id_proc

      # Cache for decrypted values - using class instance variable instead of thread_mattr_accessor
      class_attribute :_decryption_cache
      self._decryption_cache = {}
      
      # Define class methods for cache access
      class << self
        def decryption_cache
          self._decryption_cache
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
      # @param fields [Array<Symbol>] list of fields to tokenize
      # @param entity_type [String, Proc] entity type or proc that returns entity type
      # @param entity_id [Proc] proc that returns the entity ID for this record
      def tokenize_pii(fields:, entity_type:, entity_id:)
        self.tokenized_fields = fields.map(&:to_sym)
        
        self.entity_type_proc = if entity_type.is_a?(Proc)
          entity_type
        else
          ->(_) { entity_type.to_s }
        end
        
        self.entity_id_proc = entity_id

        # Define attribute accessors to intercept tokenized fields
        fields.each do |field|
          # Override reader method to decrypt on access
          define_method(field) do
            decrypt_field(field)
          end

          # Override writer method to store original value
          define_method("#{field}=") do |value|
            # Store the unencrypted value in the object, will be encrypted on save
            instance_variable_set("@original_#{field}", value)
            
            # Also need to set the attribute for the record to be dirty
            super(value)
          end
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

    # Encrypt all tokenized fields before saving
    def encrypt_pii_fields
      return if self.class.tokenized_fields.empty?

      # Collect fields that need encryption
      tokens_data = []
      
      self.class.tokenized_fields.each do |field|
        # Get the value to encrypt (either from instance var or attribute)
        value = instance_variable_get("@original_#{field}") || read_attribute(field)
        next if value.blank?
        
        tokens_data << {
          value: value,
          entity_id: entity_id,
          entity_type: entity_type,
          field_name: field.to_s
        }
      end
      
      # Encrypt in a batch
      return if tokens_data.empty?
      
      encrypted_values = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)
      
      # Update the model attributes with encrypted values
      tokens_data.each do |token_data|
        field = token_data[:field_name].to_sym
        key = "#{token_data[:entity_type]}:#{token_data[:entity_id]}:#{token_data[:field_name]}"
        
        if encrypted_values.key?(key)
          # Store the encrypted value in the database column
          write_attribute(field, encrypted_values[key])
          
          # Clear the instance variable to avoid confusion
          remove_instance_variable("@original_#{field}") if instance_variable_defined?("@original_#{field}")
          
          # Store decrypted value in cache for later access
          cache_decrypted_value(field, token_data[:value])
        end
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
        field_name: field.to_s
      }]
      
      # Perform decryption
      decrypted_values = PiiTokenizer.encryption_service.decrypt_batch(token_data)
      key = "#{entity_type}:#{entity_id}:#{field}"
      
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
      fields = fields & self.class.tokenized_fields
      
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
          field_name: field.to_s
        }
      end
      
      # Decrypt in a batch
      return {} if tokens_data.empty?
      
      decrypted_values = PiiTokenizer.encryption_service.decrypt_batch(tokens_data)
      
      # Update cache with decrypted values
      result = {}
      
      fields.each do |field|
        key = "#{entity_type}:#{entity_id}:#{field}"
        
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