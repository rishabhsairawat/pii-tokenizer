require 'active_support/concern'

# First load the version compatibility module since others depend on it
require_relative 'tokenizable/version_compatibility'

# Then load other modules in dependency order
require_relative 'tokenizable/instance_methods'
require_relative 'tokenizable/core'
require_relative 'tokenizable/field_accessors'
require_relative 'tokenizable/search'
require_relative 'tokenizable/batch_operations'
require_relative 'tokenizable/find_or_create'

module PiiTokenizer
  # Tokenizable module for handling PII tokenization in ActiveRecord models
  #
  # This module provides functionality for tokenizing sensitive personally identifiable
  # information (PII) in ActiveRecord models. It supports both Rails 4 and Rails 5+
  # with specialized handling for each version's differences.
  #
  # Key features:
  # - Transparent tokenization of PII fields
  # - Support for dual-write mode during migrations
  # - Efficient batch encryption/decryption
  # - Integration with ActiveRecord callbacks
  # - Support for searching by tokenized fields
  #
  # Implementation requires:
  # - Each tokenized field must have a corresponding _token column in the database
  # - An entity_id proc that reliably provides a unique identifier for each record
  # - An entity_type to identify the type of entity being tokenized
  #
  # @example Basic usage with guaranteed entity_id
  #   class User < ActiveRecord::Base
  #     include PiiTokenizer::Tokenizable
  #
  #     tokenize_pii fields: [:first_name, :last_name, :email],
  #                 entity_type: 'user',
  #                 entity_id: ->(user) { "user_#{user.uuid}" }
  #   end
  #
  # @example With dual-write for migration
  #   class Customer < ActiveRecord::Base
  #     include PiiTokenizer::Tokenizable
  #
  #     tokenize_pii fields: [:name, :address, :phone],
  #                 entity_type: 'customer',
  #                 entity_id: ->(customer) { "customer_#{customer.external_id}" },
  #                 dual_write: true
  #   end
  #
  # @note The entity_id proc must always return a valid entity_id string
  module Tokenizable
    extend ActiveSupport::Concern

    included do
      include VersionCompatibility
      include InstanceMethods
      include Core
      include FieldAccessors
      include Search
      include BatchOperations
      include FindOrCreate
    end

    # Make our extension module available as a constant
    DecryptedFieldsExtension = BatchOperations::DecryptedFieldsExtension
  end
end
