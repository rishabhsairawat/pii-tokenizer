require 'spec_helper'

RSpec.describe PiiTokenizer::Configuration do
  subject(:configuration) { described_class.new }

  describe 'default values' do
    it 'initializes with nil encryption_service_url' do
      expect(configuration.encryption_service_url).to be_nil
    end

    it 'has default batch_size of 20' do
      expect(configuration.batch_size).to eq(20)
    end

    it 'has default log_level of :info' do
      expect(configuration.log_level).to eq(:info)
    end

    it 'initializes logger as nil' do
      expect(configuration.logger).to be_nil
    end
  end

  describe 'custom logger' do
    let(:custom_logger) { Logger.new(StringIO.new) }

    it 'allows setting a custom logger' do
      configuration.logger = custom_logger
      expect(configuration.logger).to eq(custom_logger)
    end

    it 'allows setting log level' do
      configuration.log_level = Logger::DEBUG
      expect(configuration.log_level).to eq(Logger::DEBUG)
    end

    it 'allows setting encryption_service_url' do
      url = 'https://custom-encryption-service.example.com'
      configuration.encryption_service_url = url
      expect(configuration.encryption_service_url).to eq(url)
    end

    it 'allows setting batch_size' do
      batch_size = 50
      configuration.batch_size = batch_size
      expect(configuration.batch_size).to eq(batch_size)
    end
  end
end
