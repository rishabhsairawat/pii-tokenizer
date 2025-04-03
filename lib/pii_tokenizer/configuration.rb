module PiiTokenizer
  class Configuration
    attr_accessor :encryption_service_url, :batch_size, :logger, :log_level

    def initialize
      @encryption_service_url = nil
      @batch_size = 20
      @logger = nil
      @log_level = :info
    end
  end
end
