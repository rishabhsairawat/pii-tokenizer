module PiiTokenizer
  class Configuration
    attr_accessor :encryption_service_url, :batch_size
    
    def initialize
      @encryption_service_url = nil
      @batch_size = 20
    end
  end
end 