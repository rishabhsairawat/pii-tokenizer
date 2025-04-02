require 'spec_helper'
require 'json'
require 'webmock/rspec'

RSpec.describe PiiTokenizer::EncryptionService do
  let(:url) { 'https://encryption-service.example.com' }
  let(:config) { double('Configuration', encryption_service_url: url, batch_size: 10) }
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
              entity_type: 'CUSTOMER',
              entity_id: 'User_1',
              pii_type: 'FIRST_NAME',
              created_at: '2025-03-29T12:10:37.581+00:00'
            },
            {
              token: 'encrypted_doe',
              entity_type: 'CUSTOMER',
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
          { entity_type: 'user', entity_id: '1', pii_type: 'NAME', token: 'token1' },
          { entity_type: 'user', entity_id: '1', pii_type: 'EMAIL', token: 'token2' }
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
      expect(result).to eq('USER:1:NAME' => 'token1', 'USER:1:EMAIL' => 'token2')
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

      expect { service.encrypt_batch(tokens_data) }.to raise_error(/Encryption service error/)
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

    it 'supports legacy format with token data hashes' do
      tokens_data = [
        { token: 'token1', entity_type: 'user', entity_id: '1', pii_type: 'NAME' },
        { token: 'token2', entity_type: 'user', entity_id: '1', pii_type: 'EMAIL' }
      ]

      response_body = {
        data: [
          { token: 'token1', decrypted_value: 'John Doe' },
          { token: 'token2', decrypted_value: 'john@example.com' }
        ]
      }.to_json

      # Expect the new API format with only tokens
      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1&tokens[]=token2")
        .to_return(status: 200, body: response_body)

      result = service.decrypt_batch(tokens_data)

      # Expect the result to be formatted with entity keys for compatibility
      expect(result).to eq(
        'USER:1:NAME' => 'John Doe',
        'USER:1:EMAIL' => 'john@example.com'
      )
    end

    it 'raises error on failed response' do
      tokens = ['token1', 'token2']
      response_body = { error: 'Invalid tokens' }.to_json

      stub_request(:get, "#{url}/api/v1/tokens/decrypt?tokens[]=token1&tokens[]=token2")
        .to_return(status: 400, body: response_body)

      expect { service.decrypt_batch(tokens) }.to raise_error(/Encryption service error/)
    end
  end
end
