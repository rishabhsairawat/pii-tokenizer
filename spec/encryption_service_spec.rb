require 'spec_helper'
require 'json'
require 'webmock/rspec'
require 'stringio'
require 'logger'

RSpec.describe PiiTokenizer::EncryptionService do
  let(:url) { 'https://encryption-service.example.com' }
  # Create a null logger for tests
  let(:logger) { Logger.new(File.open(File::NULL, 'w')) }
  let(:config) { double('Configuration', encryption_service_url: url, batch_size: 10, logger: logger, log_level: :info, timeout: 10, open_timeout: 2) }
  let(:service) { described_class.new(config) }

  # Set up WebMock stubs for common requests
  before do
    # Set up WebMock to stub the API requests
    stub_request(:post, 'https://encryption-service.example.com/api/v1/tokens/bulk')
      .to_return(
        status: 200,
        body: {
          data: [
            {
              token: 'encrypted_john',
              entity_type: 'user_uuid',
              entity_id: 'User_1',
              pii_type: 'FIRST_NAME',
              created_at: '2025-03-29T12:10:37.581+00:00'
            },
            {
              token: 'encrypted_doe',
              entity_type: 'user_uuid',
              entity_id: 'User_1',
              pii_type: 'LAST_NAME',
              created_at: '2025-03-29T12:10:37.581+00:00'
            }
          ]
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    # Use a wildcard pattern for the tokens query parameters
    stub_request(:get, %r{https://encryption-service\.example\.com/api/v1/tokens/decrypt\?.*})
      .to_return(
        status: 200,
        body: {
          data: [
            {
              token: 'encrypted_john',
              decrypted_value: 'John'
            },
            {
              token: 'encrypted_doe',
              decrypted_value: 'Doe'
            }
          ]
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  describe '#encrypt_batch' do
    it 'sends a properly formatted request to the encryption service' do
      tokens_data = [
        { entity_type: 'user', entity_id: '1', value: 'John Doe', pii_type: 'NAME' },
        { entity_type: 'user', entity_id: '1', value: 'john@example.com', pii_type: 'EMAIL' }
      ]

      response_body = {
        data: [
          { entity_type: 'user', entity_id: '1', pii_type: 'NAME', pii_field: 'John Doe', token: 'token1' },
          { entity_type: 'user', entity_id: '1', pii_type: 'EMAIL', pii_field: 'john@example.com', token: 'token2' }
        ]
      }.to_json

      stub_request(:post, "#{url}/api/v1/tokens/bulk")
        .with(
          body: [
            { entity_type: 'user', entity_id: '1', pii_type: 'NAME', pii_field: 'John Doe' },
            { entity_type: 'user', entity_id: '1', pii_type: 'EMAIL', pii_field: 'john@example.com' }
          ].to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
        .to_return(status: 200, body: response_body)

      result = service.encrypt_batch(tokens_data)
      expect(result).to eq('USER:1:NAME:John Doe' => 'token1', 'USER:1:EMAIL:john@example.com' => 'token2')
    end

    it 'returns an empty hash when given an empty input' do
      expect(service.encrypt_batch([])).to eq({})
    end

    it 'raises an error when the API returns an error' do
      tokens_data = [
        { entity_type: 'user', entity_id: '1', value: 'John Doe', pii_type: 'NAME' }
      ]

      stub_request(:post, "#{url}/api/v1/tokens/bulk")
        .to_return(status: 400, body: { error: 'Invalid request' }.to_json)

      expect { service.encrypt_batch(tokens_data) }.to raise_error(RuntimeError, /Encryption service error/)
    end

    it 'correctly generates different keys based on input data' do
      tokens_data = [
        { entity_type: 'user_uuid', entity_id: '123', value: 'John', pii_type: 'NAME', field_name: 'name' },
        { entity_type: 'employee', entity_id: '456', value: 'Jane', pii_type: 'NAME', field_name: 'name' }
      ]

      response_body = {
        data: [
          { entity_type: 'user_uuid', entity_id: '123', pii_type: 'NAME', pii_field: 'John', token: 'customer_token' },
          { entity_type: 'employee', entity_id: '456', pii_type: 'NAME', pii_field: 'Jane', token: 'employee_token' }
        ]
      }.to_json

      stub_request(:post, "#{url}/api/v1/tokens/bulk")
        .to_return(status: 200, body: response_body)

      result = service.encrypt_batch(tokens_data)
      expect(result).to eq(
        'USER_UUID:123:NAME:John' => 'customer_token',
        'EMPLOYEE:456:NAME:Jane' => 'employee_token'
      )
    end

    it 'handles non-JSON responses gracefully' do
      tokens_data = [{ entity_type: 'user', entity_id: '1', value: 'John', pii_type: 'NAME' }]

      stub_request(:post, "#{url}/api/v1/tokens/bulk")
        .to_return(status: 500, body: 'Internal Server Error')

      expect { service.encrypt_batch(tokens_data) }.to raise_error(RuntimeError, /Encryption service error.*Internal Server Error/)
    end

    it 'handles empty input' do
      expect(service.encrypt_batch([])).to eq({})
    end

    it 'sanitizes data for logging' do
      # Access the private method for testing
      sanitized = service.send(:sanitize_data_for_logging, [
                                 { pii_field: 'sensitive data', entity_id: '123' },
                                 { value: 'more sensitive', other_field: 'safe' }
                               ])

      # Check that sensitive fields are redacted
      expect(sanitized).to eq([
                                { pii_field: 'REDACTED', entity_id: '123' },
                                { value: 'REDACTED', other_field: 'safe' }
                              ])
    end

    it 'sanitizes response for logging' do
      # Access the private method for testing
      json_response = '{"data":[{"token":"abc","decrypted_value":"secret"}]}'
      sanitized = service.send(:sanitize_response_for_logging, json_response)

      # Parse the resulting JSON to compare objects
      sanitized_data = JSON.parse(sanitized)

      # Check that sensitive fields are redacted
      expect(sanitized_data['data'][0]['decrypted_value']).to eq('REDACTED')
    end

    it 'handles non-JSON responses when sanitizing' do
      non_json = 'Not a JSON string'
      result = service.send(:sanitize_response_for_logging, non_json)
      expect(result).to eq('Non-JSON response')
    end
  end

  describe '#decrypt_batch' do
    it 'decrypts tokens in a batch' do
      tokens = ['token1', 'token2']
      response_body = {
        data: [
          { token: 'token1', decrypted_value: 'value1' },
          { token: 'token2', decrypted_value: 'value2' }
        ]
      }.to_json

      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1&tokens[]=token2")
        .to_return(status: 200, body: response_body)

      result = service.decrypt_batch(tokens)
      expect(result).to eq('token1' => 'value1', 'token2' => 'value2')
    end

    it 'handles single token as non-array' do
      token = 'token1'
      response_body = {
        data: [
          { token: 'token1', decrypted_value: 'value1' }
        ]
      }.to_json

      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1")
        .to_return(status: 200, body: response_body)

      result = service.decrypt_batch(token)
      expect(result).to eq('token1' => 'value1')
    end

    it 'returns empty hash for empty input' do
      expect(service.decrypt_batch([])).to eq({})
      expect(service.decrypt_batch(nil)).to eq({})
    end

    it 'raises error on failed response' do
      tokens = ['token1', 'token2']
      response_body = { error: 'Invalid tokens' }.to_json

      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1&tokens[]=token2")
        .to_return(status: 400, body: response_body)

      expect { service.decrypt_batch(tokens) }.to raise_error(RuntimeError, /Encryption service error/)
    end

    it 'handles non-JSON responses gracefully for decrypt' do
      tokens = ['token1']

      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1")
        .to_return(status: 500, body: 'Internal Server Error')

      expect { service.decrypt_batch(tokens) }.to raise_error(RuntimeError, /Encryption service error.*Internal Server Error/)
    end

    it 'handles partial matches in token to value mapping' do
      tokens_data = ['token1', 'token2', 'token3']

      response_body = {
        data: [
          { token: 'token1', decrypted_value: 'John Doe' },
          { token: 'token2', decrypted_value: 'john@example.com' }
          # No data for token3
        ]
      }.to_json

      stub_request(:get, %r{#{url}/api/v1/tokens/decrypt})
        .to_return(status: 200, body: response_body)

      result = service.decrypt_batch(tokens_data)

      # Only the matches should be in the result
      expect(result).to eq(
        'token1' => 'John Doe',
        'token2' => 'john@example.com'
      )
      expect(result['USER:1:PHONE']).to be_nil
    end

    it 'properly logs requests and responses' do
      # Create a string IO to capture log output without console logging
      log_output = StringIO.new
      test_logger = Logger.new(log_output)

      # Create a service with our test logger
      test_config = PiiTokenizer::Configuration.new
      test_config.encryption_service_url = 'https://example.com'
      test_config.logger = test_logger
      test_service = described_class.new(test_config)

      # Add the stub for Faraday response
      response = double('Response')
      allow(response).to receive(:success?).and_return(true)
      allow(response).to receive(:status).and_return(200)
      allow(response).to receive(:body).and_return('{"data":[{"token":"encrypted_token","decrypted_value":"test value"}]}')

      # Stub Faraday client
      client = double('Faraday::Connection')
      allow(client).to receive(:get).and_return(response)
      allow(test_service).to receive(:api_client).and_return(client)

      # Call the method
      test_service.decrypt_batch(['encrypted_token'])

      # Verify logging happened
      expect(log_output.string).to include('REQUEST:')
      expect(log_output.string).to include('RESPONSE:')
      expect(log_output.string).to include('REDACTED')
    end

    it 'handles error responses' do
      # Create a service
      test_config = PiiTokenizer::Configuration.new
      test_config.encryption_service_url = 'https://example.com'
      # Use a null logger to prevent output
      test_config.logger = Logger.new(File.open(File::NULL, 'w'))
      test_service = described_class.new(test_config)

      # Add the stub for error response
      response = double('Response')
      allow(response).to receive(:success?).and_return(false)
      allow(response).to receive(:status).and_return(400)
      allow(response).to receive(:body).and_return('{"error":"Invalid request"}')

      # Stub Faraday client
      client = double('Faraday::Connection')
      allow(client).to receive(:get).and_return(response)
      allow(test_service).to receive(:api_client).and_return(client)

      # Call the method and expect error
      expect do
        test_service.decrypt_batch(['encrypted_token'])
      end.to raise_error(RuntimeError, /Encryption service error/)
    end

    it 'handles non-JSON error responses' do
      # Create a service
      test_config = PiiTokenizer::Configuration.new
      test_config.encryption_service_url = 'https://example.com'
      # Use a null logger to prevent output
      test_config.logger = Logger.new(File.open(File::NULL, 'w'))
      test_service = described_class.new(test_config)

      # Add the stub for non-JSON error response
      response = double('Response')
      allow(response).to receive(:success?).and_return(false)
      allow(response).to receive(:status).and_return(500)
      allow(response).to receive(:body).and_return('Internal Server Error')

      # Stub Faraday client
      client = double('Faraday::Connection')
      allow(client).to receive(:get).and_return(response)
      allow(test_service).to receive(:api_client).and_return(client)

      # Call the method and expect error
      expect do
        test_service.decrypt_batch(['encrypted_token'])
      end.to raise_error(RuntimeError, /Encryption service error.*Internal Server Error/)
    end

    it 'handles non-JSON response when sanitizing' do
      tokens = ['token1']
      string_io = StringIO.new
      test_logger = Logger.new(string_io)
      custom_config = double('Configuration',
                             encryption_service_url: url,
                             batch_size: 10,
                             logger: test_logger,
                             log_level: Logger::INFO,
                             timeout: 10,
                             open_timeout: 2)
      service_with_custom_logger = described_class.new(custom_config)

      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1")
        .to_return(status: 200, body: 'Not JSON')

      expect { service_with_custom_logger.decrypt_batch(tokens) }.to raise_error(JSON::ParserError)

      log_output = string_io.string
      expect(log_output).to include('Non-JSON response')
    end
  end

  describe 'logging' do
    # Use StringIO to capture logs but prevent console output
    let(:string_io) { StringIO.new }
    let(:test_logger) { Logger.new(string_io) }
    let(:config_with_logger) do
      double('Configuration',
             encryption_service_url: url,
             batch_size: 10,
             logger: test_logger,
             log_level: Logger::INFO,
             timeout: 10,
             open_timeout: 2)
    end
    let(:service_with_logger) { described_class.new(config_with_logger) }

    it 'logs requests with sanitized data' do
      tokens_data = [
        { entity_type: 'user', entity_id: '1', value: 'SENSITIVE DATA', pii_type: 'NAME' }
      ]

      response_body = {
        data: [
          { entity_type: 'user', entity_id: '1', pii_type: 'NAME', token: 'token1' }
        ]
      }.to_json

      stub_request(:post, "#{url}/api/v1/tokens/bulk")
        .to_return(status: 200, body: response_body)

      service_with_logger.encrypt_batch(tokens_data)

      # Check that the sensitive data was redacted in the log
      log_output = string_io.string
      expect(log_output).to include('REQUEST:')
      expect(log_output).to include('REDACTED')
      expect(log_output).not_to include('SENSITIVE DATA')
    end

    it 'logs responses with sanitized data' do
      tokens = ['token1']
      response_body = {
        data: [
          { token: 'token1', decrypted_value: 'CONFIDENTIAL INFO' }
        ]
      }.to_json

      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1")
        .to_return(status: 200, body: response_body)

      service_with_logger.decrypt_batch(tokens)

      # Check that the sensitive decrypted value was redacted in the log
      log_output = string_io.string
      expect(log_output).to include('RESPONSE:')
      expect(log_output).to include('REDACTED')
      expect(log_output).not_to include('CONFIDENTIAL INFO')
    end

    it 'handles non-JSON response when sanitizing' do
      tokens = ['token1']
      string_io = StringIO.new
      test_logger = Logger.new(string_io)
      custom_config = double('Configuration',
                             encryption_service_url: url,
                             batch_size: 10,
                             logger: test_logger,
                             log_level: Logger::INFO,
                             timeout: 10,
                             open_timeout: 2)
      service_with_custom_logger = described_class.new(custom_config)

      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1")
        .to_return(status: 200, body: 'Not JSON')

      expect { service_with_custom_logger.decrypt_batch(tokens) }.to raise_error(JSON::ParserError)

      log_output = string_io.string
      expect(log_output).to include('Non-JSON response')
    end
  end

  describe 'initialization' do
    it 'sets up a Faraday client with the correct URL' do
      # We need to access a private method for this test
      api_client = service.send(:api_client)
      expect(api_client).to be_a(Faraday::Connection)
      expect(api_client.url_prefix.to_s).to eq(url + '/')
    end

    it 'uses a provided logger' do
      # Use a StringIO logger to prevent console output
      custom_logger = Logger.new(StringIO.new)
      config = double('Configuration',
                      encryption_service_url: url,
                      batch_size: 10,
                      logger: custom_logger,
                      log_level: :debug,
                      timeout: 10,
                      open_timeout: 2)

      service = described_class.new(config)

      # Test that the logger was set properly
      expect(service.instance_variable_get(:@logger)).to eq(custom_logger)
    end

    it 'creates a default logger when none is provided' do
      config = double('Configuration',
                      encryption_service_url: url,
                      batch_size: 10,
                      logger: nil,
                      log_level: :info,
                      timeout: 10,
                      open_timeout: 2)

      service = described_class.new(config)

      # Test that a logger was created
      expect(service.instance_variable_get(:@logger)).to be_a(Logger)

      # Optionally, redirect logger output after the test
      service.instance_variable_get(:@logger).reopen(File.open(File::NULL, 'w'))
    end
  end

  describe '#search_tokens' do
    it 'makes a properly formatted request to the search API' do
      search_value = 'john.doe@example.com'

      response_body = {
        data: [
          { token: 'token1', decrypted_value: 'john.doe@example.com' }
        ]
      }.to_json

      stub_request(:post, "#{url}/api/v1/tokens/search")
        .with(
          body: { pii_field: search_value }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
        .to_return(status: 200, body: response_body)

      result = service.search_tokens(search_value)
      expect(result).to eq(['token1'])
    end

    it 'returns an empty array when given an empty input' do
      expect(service.search_tokens(nil)).to eq([])
      expect(service.search_tokens('')).to eq([])
    end

    it 'handles multiple results correctly' do
      search_value = 'john.doe@example.com'

      response_body = {
        data: [
          { token: 'token1', decrypted_value: 'john.doe@example.com' },
          { token: 'token2', decrypted_value: 'john.doe@example.com' }
        ]
      }.to_json

      stub_request(:post, "#{url}/api/v1/tokens/search")
        .to_return(status: 200, body: response_body)

      result = service.search_tokens(search_value)
      expect(result).to contain_exactly('token1', 'token2')
    end

    it 'raises an error when the API returns an error' do
      search_value = 'john.doe@example.com'
      response_body = { error: 'Invalid request' }.to_json

      stub_request(:post, "#{url}/api/v1/tokens/search")
        .to_return(status: 400, body: response_body)

      expect { service.search_tokens(search_value) }.to raise_error(RuntimeError, /Encryption service error/)
    end

    it 'handles non-JSON responses gracefully' do
      search_value = 'john.doe@example.com'

      stub_request(:post, "#{url}/api/v1/tokens/search")
        .to_return(status: 500, body: 'Internal Server Error')

      expect { service.search_tokens(search_value) }.to raise_error(RuntimeError, /Encryption service error.*Internal Server Error/)
    end

    it 'properly logs and sanitizes data' do
      search_value = 'sensitive@email.com'

      # Create a string IO to capture log output
      log_output = StringIO.new
      test_logger = Logger.new(log_output)
      custom_config = double('Configuration',
                             encryption_service_url: url,
                             batch_size: 10,
                             logger: test_logger,
                             log_level: Logger::INFO,
                             timeout: 10,
                             open_timeout: 2)

      service_with_logger = described_class.new(custom_config)

      response_body = {
        data: [
          { token: 'token1', decrypted_value: 'sensitive@email.com' }
        ]
      }.to_json

      stub_request(:post, "#{url}/api/v1/tokens/search")
        .to_return(status: 200, body: response_body)

      service_with_logger.search_tokens(search_value)

      # Verify that sensitive data is redacted in logs
      expect(log_output.string).to include('REQUEST:')
      expect(log_output.string).to include('REDACTED')
      expect(log_output.string).not_to include('sensitive@email.com')
    end
  end
end
