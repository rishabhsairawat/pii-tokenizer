require 'spec_helper'

RSpec.describe "PiiTokenizer DualWrite Integration" do
  let(:encryption_service) { instance_double('PiiTokenizer::EncryptionService') }
  
  before do
    # Clear DB
    User.delete_all

    # Reset User class configuration to default test values
    User.tokenize_pii(
      fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
      entity_type: 'customer',
      entity_id: ->(record) { "User_customer_#{record.id}" },
      dual_write: false,
      read_from_token: true
    )

    # Stub the encryption service
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)

    # Stub encrypt_batch to return format expected by the lib
    allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
      # Generate a hash where the keys are formatted as "{ENTITY_TYPE}:{ENTITY_ID}:{PII_TYPE}:{VALUE}"
      # and values are the tokens
      result = {}
      tokens_data.each do |data|
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
        result[key] = "token_for_#{data[:value]}"
      end
      result
    end

    # Stub decrypt_batch to return expected format
    allow(encryption_service).to receive(:decrypt_batch) do |tokens|
      # Generate a hash where keys are tokens and values are decrypted values
      result = {}
      tokens.each do |token|
        # Extract original value from token (assuming format "token_for_VALUE")
        original_value = token.to_s.gsub('token_for_', '')
        result[token] = original_value
      end
      result
    end

    # Stub search_tokens
    allow(encryption_service).to receive(:search_tokens) do |value|
      ["token_for_#{value}"]
    end
  end

  after do
    # Reset User configuration
    User.tokenize_pii(
      fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
      entity_type: 'customer',
      entity_id: ->(record) { "User_customer_#{record.id}" },
      dual_write: false,
      read_from_token: true
    )
  end

  # Define a custom Log class with dual_write=true and read_from_token=false
  before do
    # Define the Log class
    class Log < ActiveRecord::Base
      include PiiTokenizer::Tokenizable
      
      connection.create_table :logs, force: true do |t|
        t.string :message
        t.string :message_token
        t.timestamps null: false
      end

      # Configure tokenization
      tokenize_pii(
        fields: { message: 'MESSAGE' },
        entity_type: 'log',
        entity_id: ->(record) { "Log_#{record.id}" },
        dual_write: true,
        read_from_token: false
      )
    end
  end

  after do
    # Clean up
    Object.send(:remove_const, :Log)
  end

  it "correctly handles dual_write=true, read_from_token=false configuration" do
    # Configure User with dual_write=true, read_from_token=false
    User.tokenize_pii(
      fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
      entity_type: 'customer',
      entity_id: ->(record) { "User_customer_#{record.id}" },
      dual_write: true,
      read_from_token: false
    )

    # Create User object - should work correctly
    user = User.create!(first_name: "John", last_name: "Doe", email: "john@example.com")
    
    # Create Log object
    log = Log.create!(message: "Hello world")

    # Verify User columns are correctly populated
    expect(user.first_name).to eq("John")
    expect(user.first_name_token).to eq("token_for_John")
    expect(user.read_attribute(:first_name)).to eq("John")

    # Verify Log columns are correctly populated
    expect(log.message).to eq("Hello world")
    expect(log.message_token).to eq("token_for_Hello world")
    expect(log.read_attribute(:message)).to eq("Hello world")
  end
end 