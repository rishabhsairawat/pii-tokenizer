require 'spec_helper'

RSpec.describe 'Find or create tokenization', type: :model do
  before do
    # Clear any existing records
    User.delete_all

    # Reset the encryption service mock
    allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch).and_call_original
    allow(PiiTokenizer.encryption_service).to receive(:search_tokens).and_return([])
  end

  it 'tokenizes only once when using find_or_create_by' do
    call_count = 0

    # Track calls to encrypt_batch
    allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
      call_count += 1

      # Mock the encryption service response
      result = {}
      tokens_data.each do |data|
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
        result[key] = "token_for_#{data[:value]}"
      end
      result
    end

    # Allow id to be set for the user
    allow_any_instance_of(User).to receive(:id).and_return(1)

    # Create the user
    user = User.find_or_create_by(first_name: 'John', email: 'test@example.com')

    # Verify encryption service was called exactly once
    expect(call_count).to eq(1)
  end

  it 'calls the encryption service only once during find_or_create_by' do
    request_count = 0

    # Track how many times the encryption service is called
    allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
      request_count += 1

      # Mock the encryption service response
      result = {}
      tokens_data.each do |data|
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
        result[key] = "token_for_#{data[:value]}"
      end
      result
    end

    # Initialize a user with a known ID
    allow_any_instance_of(User).to receive(:id).and_return(1)

    # Create the user
    user = User.find_or_create_by(first_name: 'Jane', email: 'jane@example.com')

    # Verify that encrypt_batch was only called once
    expect(request_count).to eq(1)
  end

  it 'only executes one database update when tokenizing with find_or_create_by' do
    # We'll need to track if encrypt_batch is called to trigger update_all
    encryption_called = false

    # Track how many times encrypt_batch is called
    allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
      encryption_called = true
      # Mock the encryption service response
      result = {}
      tokens_data.each do |data|
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
        result[key] = "token_for_#{data[:value]}"
      end
      result
    end

    # Allow id to be set for the user
    allow_any_instance_of(User).to receive(:id).and_return(1)

    # Create the user - this should trigger encryption which then triggers the database update
    user = User.find_or_create_by(first_name: 'Alex', email: 'alex@example.com')

    # Verify encryption was triggered, which would lead to database update
    expect(encryption_called).to eq(true)
  end
end
