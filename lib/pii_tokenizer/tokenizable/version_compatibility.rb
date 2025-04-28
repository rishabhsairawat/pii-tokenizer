module PiiTokenizer
  module Tokenizable
    module VersionCompatibility
      # Check if we're running on Rails 5 or newer
      def rails5_or_newer?
        @rails5_or_newer ||= ::ActiveRecord::VERSION::MAJOR >= 5
      end

      # Check if we're running on Rails 4.2 specifically
      def rails4_2?
        ::ActiveRecord::VERSION::MAJOR == 4 && ::ActiveRecord::VERSION::MINOR == 2
      end

      # Get the ActiveRecord version as a string
      def active_record_version
        "#{::ActiveRecord::VERSION::MAJOR}.#{::ActiveRecord::VERSION::MINOR}"
      end

      # Helper method to check if a field was changed in the current transaction
      def field_changed?(field)
        field_str = field.to_s
        token_column = "#{field_str}_token"
        
        changes_hash = if rails5_or_newer?
                        respond_to?(:previous_changes) ? previous_changes : {}
                      else
                        respond_to?(:changes) ? changes : {}
                      end
        
        # Check if either the field or its token column has changed
        changes_hash.key?(field_str) || changes_hash.key?(token_column) ||
          instance_variable_defined?("@original_#{field}") || 
          field_set_to_nil?(field.to_sym)
      end

      # Helper method to get all field changes for the current transaction
      def active_changes
        if rails5_or_newer?
          respond_to?(:previous_changes) ? previous_changes : {}
        else
          respond_to?(:changes) ? changes : {}
        end
      end

      # Safe wrapper for write_attribute that works in both Rails 4 and 5
      def safe_write_attribute(attribute, value)
        if rails5_or_newer?
          begin
            write_attribute(attribute, value)
          rescue NoMethodError
            send(:write_attribute, attribute, value) if respond_to?(:write_attribute, true)
          end
        else
          send(:write_attribute, attribute, value)
        end

        value
      end
    end
  end
end 