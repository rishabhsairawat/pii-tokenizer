module PiiTokenizer
  # Configuration class for PiiTokenizer gem
  # Holds all configuration parameters used throughout the gem
  #
  # @attr_accessor [String] encryption_service_url URL of the external encryption service
  # @attr_accessor [Integer] batch_size Maximum number of items to process in a single batch request
  # @attr_accessor [Logger, nil] logger Custom logger instance, defaults to nil
  # @attr_accessor [Symbol, Integer] log_level Logging level (:debug, :info, :warn, :error, :fatal)
  class Configuration
    attr_accessor :encryption_service_url, :batch_size, :logger, :log_level

    # Initialize a new Configuration instance with default values
    # @return [Configuration] a new instance with default settings
    def initialize
      @encryption_service_url = nil
      @batch_size = 20
      @logger = nil
      @log_level = :info
    end
  end
end
