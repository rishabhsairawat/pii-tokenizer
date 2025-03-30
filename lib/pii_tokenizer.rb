require 'pii_tokenizer/version'
require 'pii_tokenizer/configuration'
require 'pii_tokenizer/encryption_service'
require 'pii_tokenizer/tokenizable'
require 'pii_tokenizer/railtie' if defined?(Rails)

module PiiTokenizer
  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset
      @configuration = Configuration.new
    end

    def encryption_service
      @encryption_service ||= EncryptionService.new(configuration)
    end
  end
end
