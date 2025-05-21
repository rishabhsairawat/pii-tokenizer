module PiiTokenizer
  # Module for defining supported entity types
  module EntityTypes
    # User entity type
    USER_UUID = 'USER_UUID'.freeze

    # Profile entity type
    PROFILE_UUID = 'PROFILE_UUID'.freeze

    # Return all supported entity types
    def self.all
      constants.map { |const| const_get(const) }
    end

    # Check if the provided entity type is supported
    def self.supported?(entity_type)
      all.include?(entity_type)
    end
  end
end
