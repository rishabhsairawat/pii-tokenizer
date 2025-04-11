require 'spec_helper'

RSpec.describe PiiTokenizer::EncryptionService do
  let(:config) do
    config = PiiTokenizer::Configuration.new
    config.encryption_service_url = 'https://encryption-service.example.com'
    config.logger = Logger.new(File.open(File::NULL, 'w'))
    config.log_level = Logger::FATAL
    config
  end

  let(:service) { described_class.new(config) }

  describe 'initialization' do
    it 'raises an error when encryption_service_url is nil' do
      invalid_config = PiiTokenizer::Configuration.new
      expect { described_class.new(invalid_config) }.to raise_error(ArgumentError, /Encryption service URL must be configured/)
    end

    it 'raises an error when configuration is nil' do
      expect { described_class.new(nil) }.to raise_error(ArgumentError, /Configuration must not be nil/)
    end
  end

  describe 'error handling' do
    let(:faraday_connection) { instance_double(Faraday::Connection) }

    before do
      allow(Faraday).to receive(:new).and_return(faraday_connection)
    end

    describe '#encrypt_batch' do
      it 'handles connection errors gracefully' do
        expect(faraday_connection).to receive(:post)
          .and_raise(Faraday::ConnectionFailed, 'Connection failed')

        expect { service.encrypt_batch([{ value: 'test', entity_id: '1', entity_type: 'user', field_name: 'name', pii_type: 'NAME' }]) }
          .to raise_error(/Failed to connect to encryption service/)
      end

      it 'handles timeout errors gracefully' do
        expect(faraday_connection).to receive(:post)
          .and_raise(Faraday::TimeoutError, 'Timeout')

        expect { service.encrypt_batch([{ value: 'test', entity_id: '1', entity_type: 'user', field_name: 'name', pii_type: 'NAME' }]) }
          .to raise_error(/Failed to connect to encryption service/)
      end
    end

    describe '#decrypt_batch' do
      it 'handles connection errors gracefully' do
        expect(faraday_connection).to receive(:get)
          .and_raise(Faraday::ConnectionFailed, 'Connection failed')

        expect { service.decrypt_batch(['token1', 'token2']) }
          .to raise_error(/Failed to connect to encryption service/)
      end

      it 'handles timeout errors gracefully' do
        expect(faraday_connection).to receive(:get)
          .and_raise(Faraday::TimeoutError, 'Timeout')

        expect { service.decrypt_batch(['token1', 'token2']) }
          .to raise_error(/Failed to connect to encryption service/)
      end
    end

    describe '#search_tokens' do
      it 'handles connection errors gracefully' do
        expect(faraday_connection).to receive(:post)
          .and_raise(Faraday::ConnectionFailed, 'Connection failed')

        expect { service.search_tokens('test') }
          .to raise_error(/Failed to connect to encryption service/)
      end

      it 'handles timeout errors gracefully' do
        expect(faraday_connection).to receive(:post)
          .and_raise(Faraday::TimeoutError, 'Timeout')

        expect { service.search_tokens('test') }
          .to raise_error(/Failed to connect to encryption service/)
      end
    end
  end

  describe 'api_client' do
    it 'creates a new Faraday connection with the configured URL' do
      expect(Faraday).to receive(:new)
        .with(hash_including(url: 'https://encryption-service.example.com'))
        .and_call_original

      # Trigger api_client creation
      service.send(:api_client)
    end

    it 'sets timeouts on the connection' do
      conn = double('Faraday::Connection')
      options = double('Faraday::Options')
      allow(options).to receive(:timeout=)
      allow(options).to receive(:open_timeout=)
      allow(conn).to receive(:options).and_return(options)
      allow(conn).to receive(:adapter)

      expect(Faraday).to receive(:new).and_yield(conn).and_return(conn)
      expect(options).to receive(:timeout=).with(10)
      expect(options).to receive(:open_timeout=).with(5)

      # Trigger api_client creation
      service.send(:api_client)
    end
  end

  describe 'empty input handling' do
    it 'returns empty hash for nil input to encrypt_batch' do
      expect(service.encrypt_batch(nil)).to eq({})
    end

    it 'returns empty hash for empty array to encrypt_batch' do
      expect(service.encrypt_batch([])).to eq({})
    end

    it 'returns empty hash for nil input to decrypt_batch' do
      expect(service.decrypt_batch(nil)).to eq({})
    end

    it 'returns empty hash for empty array to decrypt_batch' do
      expect(service.decrypt_batch([])).to eq({})
    end

    it 'returns empty array for nil input to search_tokens' do
      expect(service.search_tokens(nil)).to eq([])
    end

    it 'returns empty array for empty string to search_tokens' do
      expect(service.search_tokens('')).to eq([])
    end
  end
end
