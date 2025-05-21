module PiiTokenizer
  module Tokenizable
    module VersionCompatibility
      # We only support Rails 4.2 now, so we don't need version checks.
      # In future, we can use this module to support other versions.

      # Safe wrapper for write_attribute that works in Rails 4.2
      def safe_write_attribute(attribute, value)
        send(:write_attribute, attribute, value)
        value
      end
    end
  end
end
