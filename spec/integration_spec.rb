require 'spec_helper'
require 'webmock/rspec'

RSpec.describe 'Integration tests', type: :model do
  before do
    User.delete_all

    # Ensure WebMock is enabled
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  after do
    WebMock.reset!
  end

  it 'makes only one tokenization request with find_or_create_by' do
    # Set up a counter to track service calls
    request_count = 0

    # Ensure we have a clean start
    User.delete_all

    # Create a real mock of the encryption service
    encryption_service = instance_double(PiiTokenizer::EncryptionService)
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)

    # Stub search_tokens to return empty results (force creation)
    allow(encryption_service).to receive(:search_tokens).and_return([])

    # Mock encrypt_batch to return tokens
    allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
      request_count += 1

      result = {}
      tokens_data.each do |data|
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
        result[key] = "token_for_#{data[:value]}"
      end
      result
    end

    # Stub decrypt_batch to return decrypted values
    allow(encryption_service).to receive(:decrypt_batch) do |tokens|
      result = {}
      tokens = [tokens] unless tokens.is_a?(Array)

      tokens.each do |token|
        if token&.to_s&.start_with?('token_for_')
          decrypted = token.to_s.sub('token_for_', '')
          result[token] = decrypted
        end
      end
      result
    end

    # Create a user with find_or_create_by
    user = User.find_or_create_by(
      first_name: 'John',
      last_name: 'Doe',
      email: 'john@example.com'
    )

    # Verify that encrypt_batch was called exactly once
    expect(request_count).to eq(1)

    # Now verify the token fields are set correctly
    expect(user.first_name_token).to eq('token_for_John')
    expect(user.last_name_token).to eq('token_for_Doe')
    expect(user.email_token).to eq('token_for_john@example.com')
  end
end
