require 'spec_helper'

RSpec.describe PiiTokenizer do
  describe 'module functionality' do
    it 'has a version number' do
      expect(PiiTokenizer::VERSION).not_to be_nil
    end

    it 'can be configured via block' do
      test_url = 'https://test-encryption-service.example.com'
      test_batch_size = 25

      described_class.configure do |config|
        config.encryption_service_url = test_url
        config.batch_size = test_batch_size
      end

      expect(described_class.configuration.encryption_service_url).to eq(test_url)
      expect(described_class.configuration.batch_size).to eq(test_batch_size)
    end

    it 'returns configuration when not explicitly configured' do
      # Reset configuration to defaults
      current_config = described_class.configuration
      described_class.instance_variable_set(:@configuration, nil)

      # Get new config
      new_config = described_class.configuration
      expect(new_config).to be_a(PiiTokenizer::Configuration)

      # Restore original config
      described_class.configuration = current_config
    end

    it 'allows direct setting of configuration' do
      original_config = described_class.configuration

      config = PiiTokenizer::Configuration.new
      config.encryption_service_url = 'https://another-test.example.com'

      described_class.configuration = config

      expect(described_class.configuration).to eq(config)
      expect(described_class.configuration.encryption_service_url).to eq('https://another-test.example.com')

      # Restore original config
      described_class.configuration = original_config
    end

    it 'provides access to the encryption service' do
      expect(described_class.encryption_service).to be_a(PiiTokenizer::EncryptionService)
    end
  end
end
