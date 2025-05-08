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
  # Key Rails version differences handled:
  # - In Rails 5+, `previous_changes` contains changes after save, while in Rails 4, `changes` has this data
  # - Method visibility differences (private vs public) between Rails versions
  # - Different method implementations for record updates and inserts
  #
  # The module ensures that tokenization works correctly regardless of Rails version by:
  # - Using version detection helpers (rails5_or_newer?)
  # - Providing compatibility layers (field_changed?, active_changes)
  # - Implementing special method handling for Rails 4 compatibility (method_missing)
  #
  # @example Basic usage
  #   class User < ActiveRecord::Base
  #     include PiiTokenizer::Tokenizable
  #
  #     tokenize_pii fields: [:first_name, :last_name, :email],
  #                 entity_type: 'user_uuid',
  #                 entity_id: ->(user) { "user_#{user.id}" }
  #   end
  #
  # @note Each tokenized field should have a corresponding _token column in the database
  #       (e.g., first_name should have first_name_token column)
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
