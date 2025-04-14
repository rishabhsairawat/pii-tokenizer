require 'active_support/concern'
require 'logger'

# Setup basic logging - Consumers can reconfigure this
# PiiTokenizer.logger = Logger.new(STDOUT)
# PiiTokenizer.logger.level = Logger::INFO # Or DEBUG for more verbose output

module PiiTokenizer
  # Central configuration
  class << self
    attr_accessor :encryption_service, :logger
  end

  # Default logger setup - can be overridden by the application
  self.logger ||= Logger.new(STDOUT)
  self.logger.level ||= Logger::INFO

  # Add a specific marker for nil values in the cache
  NIL_MARKER = Object.new.freeze

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
        field_str = field.to_s # Ensure we have the string form
        return nil unless self.class.tokenized_fields.include?(field_sym)

        # If this field is flagged to be set to nil, return nil without decrypting
        if instance_variable_defined?("@#{field}_set_to_nil") &&
           instance_variable_get("@#{field}_set_to_nil")
          return nil
        end

        # Check cache first
        if field_decryption_cache.key?(field_sym)
          # If the cached value is the specific nil marker, return actual nil
          cached_value = field_decryption_cache[field_sym]
          return nil if cached_value == PiiTokenizer::NIL_MARKER
          return cached_value
        end

        # Get the token value
        token_column = token_column_for(field_str)
        encrypted_value = read_attribute(token_column)

        # Return nil for nil/blank token values
        return nil if encrypted_value.blank?

        # Decrypt the value
        # Store original value *before* decryption attempt for fallback
        original_persisted_value = read_attribute(field)
        result = PiiTokenizer.encryption_service.decrypt_batch([encrypted_value])
        decrypted_value = result[encrypted_value]

        # Cache and return decrypted value, or fallback to original persisted value
        if decrypted_value
          field_decryption_cache[field_sym] = decrypted_value
          decrypted_value
        else
          # Fallback: Fetch the raw value directly from DB to avoid recursion
          fallback_value = nil
          if persisted?
            # Use unscoped to bypass default scopes, pick for single value efficiency
            fallback_value = self.class.unscoped.where(id: self.id).pick(field_str)
          end

          # Cache the determined fallback value
          field_decryption_cache[field_sym] = fallback_value.nil? ? PiiTokenizer::NIL_MARKER : fallback_value
          fallback_value
        end
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
            # Ensure we read the *persisted* original value
            fallback_value = read_attribute(field)
            result[field] = fallback_value
            # Cache the fallback value too, marking nils
            field_decryption_cache[field] = fallback_value.nil? ? PiiTokenizer::NIL_MARKER : fallback_value
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
        # Use a specific marker for nil values to differentiate from uncached
        field_decryption_cache[field.to_sym] = value.nil? ? PiiTokenizer::NIL_MARKER : value
      end

      # Get a cached decrypted value for a field
      def get_cached_decrypted_value(field)
        cached = field_decryption_cache[field.to_sym]
        cached == PiiTokenizer::NIL_MARKER ? nil : cached
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

      # Method definitions moved out of private to potentially help with callback registration
      # Prepare PII fields before saving
      def prepare_pii_for_save
        @_pii_pending_changes ||= {}

        self.class.tokenized_fields.each do |field|
          field_str = field.to_s
          original_value_set = instance_variable_defined?("@original_#{field}")
          set_to_nil = instance_variable_defined?("@#{field}_set_to_nil") && instance_variable_get("@#{field}_set_to_nil")

          # If the writer was called (setting a value or nil), check if it's a real change
          if original_value_set || set_to_nil
            new_value = set_to_nil ? nil : instance_variable_get("@original_#{field}")

            # Use ActiveModel::Dirty's `changes` hash to see if the attribute was assigned
            # a different value during this save cycle, even if changed back.
            # The `attribute_changed?` check can be less reliable depending on AR version/usage.
            # Also include explicit nils and always tokenize new records with present values.
            marked_changed = changes.key?(field_str)
            changed = (new_record? && new_value.present?) || set_to_nil || marked_changed

            # Only mark as pending if changed
            if changed
              @_pii_pending_changes[field] = new_value

              # If not dual writing, clear the original field attribute now
              unless self.class.dual_write_enabled
                write_attribute(field_str, nil)
              end
            end
          end
        end
      end

      # Tokenize PII fields after save
      def tokenize_pii_after_save
        # === Move entity_id check earlier ===
        entity_id = self.class.entity_id_proc.call(self)
        unless entity_id.present?
          PiiTokenizer.logger.warn("[#{self.class.name}] Skipping PII tokenization for record #{id || 'new'}: entity_id is blank.")
          # Clear pending changes even if we skip, to prevent re-processing if somehow set
          @_pii_pending_changes = nil
          return
        end
        # =================================

        # Now check for pending changes
        return if @_pii_pending_changes.blank?
        return unless destroyed? == false # Don't run on destroy

        entity_type = self.class.entity_type_proc.call(self)
        # entity_id already fetched

        pending_changes = @_pii_pending_changes.dup # Work on a copy
        @_pii_pending_changes = nil # Clear original immediately

        tokens_data = []
        updates = {}

        pending_changes.each do |field, value|
          field_str = field.to_s
          token_column = token_column_for(field_str)

          if value.nil? || (value.respond_to?(:blank?) && value.blank?)
            # Field set to nil or blank
            # Only add token_column update if dual_write is disabled.
            # If dual_write is enabled, the main save handles setting cols to nil.
            if !self.class.dual_write_enabled
              # Only add update if token column isn't already nil
              updates[token_column] = nil if read_attribute(token_column).present?
            end
            field_decryption_cache[field] = PiiTokenizer::NIL_MARKER # Update cache
          else
            # Field has a value to tokenize
            pii_type = self.class.pii_types[field_str]
            unless pii_type.blank?
              tokens_data << {
                value: value,
                entity_id: entity_id,
                entity_type: entity_type,
                field_name: field_str,
                pii_type: pii_type
              }
            else
              PiiTokenizer.logger.warn("[#{self.class.name}] Missing pii_type for field #{field_str} on record #{id}, cannot tokenize.")
            end
          end
        end

        # Encrypt in batch
        if tokens_data.any?
          begin
            key_to_token = PiiTokenizer.encryption_service.encrypt_batch(tokens_data)

            tokens_data.each do |token_data|
              field = token_data[:field_name]
              # Use field_name (pii_field) for lookup key generation, matching encryption_service
              key = "#{token_data[:entity_type].upcase}:#{token_data[:entity_id]}:#{token_data[:pii_type]}:#{token_data[:field_name]}"
              token_column = token_column_for(field)

              if key_to_token.key?(key)
                token = key_to_token[key]
                updates[token_column] = token
                # If not dual-writing, ensure original field is nil in DB update
                updates[field] = nil unless self.class.dual_write_enabled
                # Cache the original value after successful encryption
                field_decryption_cache[field.to_sym] = token_data[:value]
              else
                PiiTokenizer.logger.error("[#{self.class.name}] Encryption service did not return token for key '#{key}' on record #{id}.")
              end
            end
          rescue => e
            PiiTokenizer.logger.error("[#{self.class.name}] Error calling encryption service for record #{id}: #{e.message}")
            return # Don't proceed with DB updates if encryption failed
          end
        end

        # Apply updates using update_all only if there are changes to apply
        if updates.any?
          begin
            self.class.unscoped.where(id: id).update_all(updates)
            # Manually update in-memory attributes
            updates.each do |col, val|
              write_attribute(col, val)
            end
            # Clear tracking instance variables for processed fields
            pending_changes.keys.each do |field|
              remove_instance_variable("@original_#{field}") if instance_variable_defined?("@original_#{field}")
              remove_instance_variable("@#{field}_set_to_nil") if instance_variable_defined?("@#{field}_set_to_nil")
            end
          rescue => e
            PiiTokenizer.logger.error("[#{self.class.name}] Error updating token columns for record #{id}: #{e.message}")
          end
        else
          # If updates hash is empty (e.g., only nil changes in dual-write mode),
          # still clear the tracking instance variables
          pending_changes.keys.each do |field|
             remove_instance_variable("@original_#{field}") if instance_variable_defined?("@original_#{field}")
             remove_instance_variable("@#{field}_set_to_nil") if instance_variable_defined?("@#{field}_set_to_nil")
          end
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
              cached_value = field_decryption_cache[field]
              # IMPORTANT: Return nil if marker found, not the marker itself
              return nil if cached_value == PiiTokenizer::NIL_MARKER
              return cached_value
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
            # Read the current value *before* setting
            current_value = public_send(field)

            # Skip if the value hasn't actually changed
            return value if value == current_value

            # Store the original (unencrypted) value in an instance variable
            instance_variable_set("@original_#{field}", value)

            if value.nil?
              # Flag that nil was explicitly set
              instance_variable_set("@#{field}_set_to_nil", true)
              remove_instance_variable("@original_#{field}") # Don't need original if nil
              # Update decryption cache immediately
              field_decryption_cache[field.to_sym] = PiiTokenizer::NIL_MARKER

              # If dual writing, ensure the token column is also marked dirty for the main save
              if self.class.dual_write_enabled
                token_column = token_column_for(field)
                attribute_will_change!(token_column) if respond_to?(:attribute_will_change!, true)
                write_attribute(token_column, nil)
              end
            else
              # Clear the nil flag if previously set
              remove_instance_variable("@#{field}_set_to_nil") if instance_variable_defined?("@#{field}_set_to_nil")
              # Update decryption cache immediately
              field_decryption_cache[field.to_sym] = value
            end

            # Call super to let ActiveRecord handle change tracking and standard saving,
            # but only if the superclass actually defines the method (for non-AR attributes).
            if defined?(super)
              super(value)
            else
              # If no super method (e.g., attribute not defined on AR::Base),
              # we still might need to mark the record as dirty manually if AR change tracking isn't involved.
              # This part is complex and might depend on how non-AR attributes are expected to work.
              # For now, we just skip super if it's not defined.
              # Consider if change tracking needs manual trigger here for non-column attributes.
            end
          end
        end
      end
    end

    # Module containing class methods for searching
    module SearchMethods
      extend ActiveSupport::Concern

      class_methods do
        # Search for a record by a tokenized field
        def search_by_tokenized_field(field, value)
          # Ensure this method is only used for configured tokenized fields
          field_sym = field.to_sym
          unless tokenized_fields.include?(field_sym)
            raise ArgumentError, "`#{field}` is not configured for tokenization on #{self.name}"
          end

          return nil if value.nil?

          # Only search token column if configured to do so
          unless read_from_token_column
            # Fallback to searching the original field if not reading from token column
            return where(field_sym => value).first
          end

          # Get the token column
          token_column = "#{field_sym}_token"

          # Search for tokens that match the value
          tokens = PiiTokenizer.encryption_service.search_tokens(value)
          return nil if tokens.empty?

          # Find records where the token column matches any of the returned tokens
          where(token_column => tokens).first
        end

        # Search for all records matching a tokenized field value
        def search_all_by_tokenized_field(field, value)
          # Ensure this method is only used for configured tokenized fields
          field_sym = field.to_sym
          unless tokenized_fields.include?(field_sym)
            raise ArgumentError, "`#{field}` is not configured for tokenization on #{self.name}"
          end

          return [] if value.nil?

          # Only search token column if configured to do so
          unless read_from_token_column
            # Fallback to searching the original field if not reading from token column
            return where(field_sym => value)
          end

          # Get the token column
          token_column = "#{field_sym}_token"

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
          # Use our dedicated finder logic
          record = find_record_by_tokenized_attributes(attributes)

          # If found, return it
          return record if record

          # If not found, initialize a new one with the attributes
          new(attributes) # Let standard initializer handle setting attributes
        end

        # Explicitly override find_by to use our tokenized logic
        def find_by(attributes)
          # Use our dedicated finder logic
          find_record_by_tokenized_attributes(attributes)
        end

        # Override find_or_create_by to handle tokenized fields
        def find_or_create_by(attributes, &block)
          # Use our dedicated finder logic
          record = find_record_by_tokenized_attributes(attributes)

          # If found, return it
          return record if record

          # If not found, create a new one with the attributes
          # Use transaction for atomicity if block is given or for standard AR behavior
          transaction(requires_new: true) do
            record = new(attributes)
            # Use standard save! which will trigger our callbacks
            record.save!
            # Run any validation block if provided
            yield(record) if block_given?
          end

          record
        rescue ActiveRecord::RecordInvalid
          # If save fails due to validation, return the invalid record
          record
        end

        private

        # Find a record matching the given attributes, prioritizing tokenized fields
        def find_record_by_tokenized_attributes(attributes)
          tokenized_conditions = {}
          standard_conditions = {}

          # Separate tokenized and standard conditions
          attributes.each do |key, value|
            key_sym = key.to_sym
            if tokenized_fields.include?(key_sym) && value.present? && read_from_token_column
              tokens = PiiTokenizer.encryption_service.search_tokens(value)
              # If a tokenized field yields no search tokens, no record can match
              return nil if tokens.empty?
              token_column = token_column_for(key_sym)
              tokenized_conditions[token_column] = tokens
            else
              # Use standard attribute for nil values, non-tokenized fields,
              # or when read_from_token_column is false
              standard_conditions[key] = value
            end
          end

          # Build the query
          relation = where(standard_conditions)
          tokenized_conditions.each do |token_column, tokens|
            relation = relation.where(token_column => tokens)
          end

          # Find the first matching record
          relation.first
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

      # Callbacks
      before_save :prepare_pii_for_save
      after_save :tokenize_pii_after_save

      # Register for decryption on load
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
    end

    # Make our extension module available as a constant
    DecryptedFieldsExtension = BatchOperations::DecryptedFieldsExtension
  end
end
