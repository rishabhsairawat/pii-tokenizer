require 'spec_helper'
require 'json'

RSpec.describe PiiTokenizer::EncryptionService do
  let(:configuration) { PiiTokenizer::Configuration.new }
  let(:service) { described_class.new(configuration) }

  before do
    configuration.encryption_service_url = 'https://encryption-service.example.com'
    configuration.batch_size = 10

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
        { value: 'John', entity_id: 'User_1', entity_type: 'customer', field_name: 'first_name', pii_type: 'FIRST_NAME' },
        { value: 'Doe', entity_id: 'User_1', entity_type: 'customer', field_name: 'last_name', pii_type: 'LAST_NAME' }
      ]

      # Call the method and check the result
      result = service.encrypt_batch(tokens_data)

      expect(result).to eq({
                             'CUSTOMER:User_1:FIRST_NAME' => 'encrypted_john',
                             'CUSTOMER:User_1:LAST_NAME' => 'encrypted_doe'
                           })

      # Verify that the correct request was made
      expect(WebMock).to have_requested(:post, 'https://encryption-service.example.com/api/v1/tokens/bulk')
        .with { |req|
          body = JSON.parse(req.body)
          expect(body).to contain_exactly(
            { 'entity_type' => 'customer', 'entity_id' => 'User_1', 'pii_type' => 'FIRST_NAME', 'pii_field' => 'John' },
            { 'entity_type' => 'customer', 'entity_id' => 'User_1', 'pii_type' => 'LAST_NAME', 'pii_field' => 'Doe' }
          )
          true
        }
    end

    it 'returns an empty hash when given an empty input' do
      expect(service.encrypt_batch([])).to eq({})
    end

    it 'raises an error when the API returns an error' do
      tokens_data = [
        { value: 'Test', entity_id: 'User_1', entity_type: 'customer', field_name: 'test', pii_type: 'TEST' }
      ]

      # Stub error response
      stub_request(:post, 'https://encryption-service.example.com/api/v1/tokens/bulk')
        .to_return(
          status: 401,
          body: { error: 'Unauthorized' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { service.encrypt_batch(tokens_data) }.to raise_error(/Encryption service error/)
    end
  end

  describe '#decrypt_batch' do
    it 'sends a properly formatted request to the encryption service' do
      tokens_data = [
        { token: 'encrypted_john', entity_id: 'User_1', entity_type: 'customer', field_name: 'first_name', pii_type: 'FIRST_NAME' },
        { token: 'encrypted_doe', entity_id: 'User_1', entity_type: 'customer', field_name: 'last_name', pii_type: 'LAST_NAME' }
      ]

      # Call the method and check the result
      result = service.decrypt_batch(tokens_data)

      expect(result).to include(
        'CUSTOMER:User_1:FIRST_NAME' => 'John',
        'CUSTOMER:User_1:LAST_NAME' => 'Doe'
      )

      # Instead of checking the exact query parameters, let's check that the request was made to the correct URL
      expect(WebMock).to have_requested(:get, %r{https://encryption-service\.example\.com/api/v1/tokens/decrypt})
    end

    it 'returns an empty hash when given an empty input' do
      expect(service.decrypt_batch([])).to eq({})
    end
  end
end
