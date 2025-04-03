# Configure PiiTokenizer gem
PiiTokenizer.configure do |config|
  # URL of the encryption service API
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL']

  # Maximum number of fields to encrypt/decrypt in a single batch API call
  # Adjust this based on your encryption service's limits and performance needs
  config.batch_size = 20

  # Logging configuration
  # By default, logs to STDOUT. You can set your own logger:
  # config.logger = Rails.logger

  # Set the log level (debug, info, warn, error, fatal)
  # config.log_level = :info
end
