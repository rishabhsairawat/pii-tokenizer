require 'pii_tokenizer/version'
require 'pii_tokenizer/configuration'
require 'pii_tokenizer/encryption_service'
require 'pii_tokenizer/tokenizable'
require 'pii_tokenizer/railtie' if defined?(Rails)

# PiiTokenizer is a Ruby gem for tokenizing Personally Identifiable Information (PII)
# in ActiveRecord models. It provides a secure way to store sensitive data by
# replacing it with tokens via an external encryption service.
#
# @example Basic usage with an ActiveRecord model
#   class User < ActiveRecord::Base
#     include PiiTokenizer::Tokenizable
#
#     tokenize_pii fields: [:first_name, :last_name, :email],
#                  entity_type: 'user_uuid',
#                  entity_id: ->(user) { "user_#{user.id}" }
#   end
#
# @example Configuration in an initializer
#   # config/initializers/pii_tokenizer.rb
#   PiiTokenizer.configure do |config|
#     config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL']
#     config.batch_size = 20
#     config.logger = Rails.logger
#   end
module PiiTokenizer
  class << self
    attr_writer :configuration

    # Get the current configuration
    # @return [PiiTokenizer::Configuration] Current configuration instance
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure the gem with a block
    # @yield [config] Configuration object for setup
    def configure
      yield(configuration)
    end

    # Reset the configuration to defaults
    # @return [PiiTokenizer::Configuration] New configuration instance
    def reset
      @configuration = Configuration.new
    end

    # Get the encryption service instance
    # @return [PiiTokenizer::EncryptionService] Encryption service instance
    def encryption_service
      @encryption_service ||= EncryptionService.new(configuration)
    end
  end
end
