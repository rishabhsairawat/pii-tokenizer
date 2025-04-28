require 'active_support/concern'

module PiiTokenizer
  module Tokenizable
    module Search
      extend ActiveSupport::Concern

      class_methods do
        include VersionCompatibility

        # Override the default ActiveRecord where method to handle tokenized fields
        def where(opts = :chain, *rest)
          # Handle :chain case for proper method chaining
          if opts == :chain
            return super
          end

          # For non-hash conditions, use default behavior
          unless opts.is_a?(Hash)
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
                if read_from_token_column
                  # When reading from token column, search by token
                  tokens = PiiTokenizer.encryption_service.search_tokens(value)

                  # If no tokens found, return empty relation
                  if tokens.empty?
                    return none
                  end

                  # Add condition to search token column for matching tokens
                  token_column = "#{key_sym}_token"
                  tokenized_conditions[token_column] = tokens
                else
                  # When not reading from token column, search by original field
                  standard_conditions[key] = value
                end
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

        # Handle dynamic finder methods
        def method_missing(method_name, *args, &block)
          # Handle dynamic finders (e.g., find_by_email)
          if handle_dynamic_finder?(method_name, *args)
            return handle_dynamic_finder(method_name, *args)
          end

          # Handle Rails 4 compatibility methods
          if handle_rails4_method?(method_name)
            return handle_rails4_method(method_name, *args)
          end

          super
        end

        # Check if we respond to a method
        def respond_to_missing?(method_name, include_private = false)
          # Handle Rails 4 specific methods
          if handle_rails4_method?(method_name)
            return true
          end

          # Handle dynamic finders
          method_str = method_name.to_s
          if method_str.start_with?('find_by_')
            field_name = method_str.sub('find_by_', '')
            return tokenized_fields.include?(field_name.to_sym)
          end

          super
        end

        private

        # Check if method is a Rails 4 specific method that needs special handling
        def handle_rails4_method?(method_name)
          return false unless rails4_2?

          # These methods need special handling in Rails 4.2
          %i[insert _update_record].include?(method_name)
        end

        # Handle dynamic finder methods
        def handle_dynamic_finder?(method_name, *args)
          method_str = method_name.to_s
          method_str.start_with?('find_by_') && args.size == 1
        end

        # Process dynamic finder methods
        def handle_dynamic_finder(method_name, *args)
          method_str = method_name.to_s
          field_name = method_str.sub('find_by_', '')
          field_sym = field_name.to_sym

          if tokenized_fields.include?(field_sym)
            if read_from_token_column
              # When reading from token, use tokenized search
              return search_by_tokenized_field(field_sym, args.first)
            else
              # When not reading from token, use standard field
              return where(field_sym => args.first).first
            end
          end
          nil
        end

        # Handle Rails 4 specific methods
        def handle_rails4_method(_method_name, *_args)
          # For Rails 4 compatibility, simply return true to allow the operation
          # to continue without breaking the chain
          true
        end
      end
    end
  end
end 