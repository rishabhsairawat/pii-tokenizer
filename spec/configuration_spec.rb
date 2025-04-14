require 'spec_helper'
require 'logger'
require 'stringio'

RSpec.describe PiiTokenizer::Configuration do
  let(:config) { described_class.new }

  describe 'initialization' do
    it 'has default values' do
      expect(config.encryption_service_url).to be_nil
      expect(config.batch_size).to eq(20)
      expect(config.logger).to be_nil
      expect(config.log_level).to eq(:info)
    end
  end

  describe 'attribute accessors' do
    it 'allows setting encryption_service_url' do
      config.encryption_service_url = 'https://encryption-service.example.com'
      expect(config.encryption_service_url).to eq('https://encryption-service.example.com')
    end

    it 'allows setting batch_size' do
      config.batch_size = 50
      expect(config.batch_size).to eq(50)
    end

    it 'allows setting logger' do
      logger = Logger.new(StringIO.new)
      config.logger = logger
      expect(config.logger).to eq(logger)
    end

    it 'allows setting log_level' do
      config.log_level = :debug
      expect(config.log_level).to eq(:debug)
    end
  end

  describe 'in PiiTokenizer module' do
    before do
      # Reset PiiTokenizer configuration
      PiiTokenizer.instance_variable_set(:@configuration, nil)
    end

    it 'can be configured via block' do
      PiiTokenizer.configure do |config|
        config.encryption_service_url = 'https://example.com/api'
        config.batch_size = 100
      end

      expect(PiiTokenizer.configuration.encryption_service_url).to eq('https://example.com/api')
      expect(PiiTokenizer.configuration.batch_size).to eq(100)
    end

    it 'returns default configuration when not explicitly configured' do
      config = PiiTokenizer.configuration

      expect(config).to be_a(described_class)
      expect(config.encryption_service_url).to be_nil
      expect(config.batch_size).to eq(20)
    end

    it 'allows direct setting of configuration' do
      custom_config = described_class.new
      custom_config.encryption_service_url = 'https://custom.example.com'

      PiiTokenizer.configuration = custom_config

      expect(PiiTokenizer.configuration).to eq(custom_config)
      expect(PiiTokenizer.configuration.encryption_service_url).to eq('https://custom.example.com')
    end

    it 'can reset configuration to defaults' do
      PiiTokenizer.configure do |config|
        config.encryption_service_url = 'https://example.com/api'
        config.batch_size = 100
      end

      PiiTokenizer.reset

      expect(PiiTokenizer.configuration.encryption_service_url).to be_nil
      expect(PiiTokenizer.configuration.batch_size).to eq(20)
    end

    it 'provides access to the encryption service' do
      PiiTokenizer.configure do |config|
        config.encryption_service_url = 'https://example.com/api'
      end

      expect(PiiTokenizer.encryption_service).to be_a(PiiTokenizer::EncryptionService)

      # Should return the same instance when called multiple times
      service1 = PiiTokenizer.encryption_service
      service2 = PiiTokenizer.encryption_service
      expect(service1).to eq(service2)
    end
  end

  it 'allows setting and getting the encryption_service_url' do
    config.encryption_service_url = 'https://example.com'
    expect(config.encryption_service_url).to eq('https://example.com')
  end

  it 'allows setting and getting the log_level' do
    config.log_level = Logger::DEBUG
    expect(config.log_level).to eq(Logger::DEBUG)
  end

  it 'allows setting and getting a custom logger' do
    custom_logger = Logger.new(StringIO.new)
    config.logger = custom_logger
    expect(config.logger).to eq(custom_logger)
  end

  it 'creates a default logger when none is specified' do
    # Set required encryption_service_url to avoid ArgumentError
    config.encryption_service_url = 'https://example.com'

    # When logger is not set, EncryptionService creates a default one
    service = PiiTokenizer::EncryptionService.new(config)
    expect(service.instance_variable_get(:@logger)).to be_a(Logger)
  end
end
