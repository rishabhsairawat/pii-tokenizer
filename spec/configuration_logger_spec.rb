require 'spec_helper'
require 'logger'

RSpec.describe PiiTokenizer::Configuration do
  describe 'default values' do
    let(:config) { described_class.new }

    it 'initializes with nil encryption_service_url' do
      expect(config.encryption_service_url).to be_nil
    end

    it 'has default batch_size of 20' do
      expect(config.batch_size).to eq(20)
    end

    it 'has default log_level of :info' do
      expect(config.log_level).to eq(:info)
    end

    it 'initializes logger as nil' do
      expect(config.logger).to be_nil
    end
  end

  describe 'custom logger' do
    let(:config) { described_class.new }
    let(:logger) { Logger.new(STDOUT) }

    it 'allows setting a custom logger' do
      config.logger = logger
      expect(config.logger).to eq(logger)
    end

    it 'allows setting log level' do
      config.log_level = :debug
      expect(config.log_level).to eq(:debug)
    end

    it 'allows setting encryption_service_url' do
      url = 'https://encryption-service.example.com'
      config.encryption_service_url = url
      expect(config.encryption_service_url).to eq(url)
    end

    it 'allows setting batch_size' do
      config.batch_size = 50
      expect(config.batch_size).to eq(50)
    end
  end
end
