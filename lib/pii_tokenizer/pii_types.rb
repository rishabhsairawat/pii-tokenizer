module PiiTokenizer
  # Predefined PII types to ensure consistency across tokenization
  module PiiTypes
    # Personal identity types
    EMAIL = 'EMAIL'.freeze
    PHONE = 'PHONE'.freeze
    NAME = 'NAME'.freeze
    URL = 'URL'.freeze

    # Get all supported PII types
    def self.all
      constants.map { |const| const_get(const) }
    end

    # Check if a PII type is supported
    def self.supported?(type)
      all.include?(type.to_s.upcase)
    end
  end
end
