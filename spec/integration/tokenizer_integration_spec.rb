require 'spec_helper'

RSpec.describe 'PiiTokenizer Integration' do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    # Clear existing users
    User.delete_all

    # Setup the encryption service mock
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)

    # Setup encryption service to return expected tokens
    allow(encryption_service).to receive(:encrypt_batch) do |data|
      # Generate tokens for the batch
      result = {}
      data.each do |item|
        key = "#{item[:entity_type].upcase}:#{item[:entity_id]}:#{item[:pii_type]}:#{item[:value]}"
        result[key] = "token_for_#{item[:value]}"
      end
      result
    end

    # Mock decryption of these tokens
    allow(encryption_service).to receive(:decrypt_batch) do |tokens|
      result = {}
      # Ensure tokens is an array
      tokens = [tokens] unless tokens.is_a?(Array)

      tokens.each do |token|
        next unless token.to_s.start_with?('token_for_')

        # Extract original value from token format
        original = token.to_s.sub('token_for_', '')
        result[token] = original
      end
      result
    end

    # Mock search tokens function
    allow(encryption_service).to receive(:search_tokens) do |value|
      ["token_for_#{value}"]
    end
  end

  describe 'basic functionality' do
    it 'tokenizes fields on save' do
      # Configure User model
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { record.id.to_s },
        dual_write: false,
        read_from_token: true
      )

      # Create a user
      user = User.create!(first_name: 'John', last_name: 'Doe', email: 'john@example.com')

      # Verify token columns contain tokens
      expect(user.first_name_token).to eq('token_for_John')
      expect(user.last_name_token).to eq('token_for_Doe')
      expect(user.email_token).to eq('token_for_john@example.com')

      # Verify original fields are nil in the database
      expect(user.read_attribute(:first_name)).to be_nil
      expect(user.read_attribute(:last_name)).to be_nil
      expect(user.read_attribute(:email)).to be_nil

      # Verify accessor methods return decrypted values
      expect(user.first_name).to eq('John')
      expect(user.last_name).to eq('Doe')
      expect(user.email).to eq('john@example.com')
    end

    it 'supports dual write mode' do
      # Configure User model with dual_write=true
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { record.id.to_s },
        dual_write: true,
        read_from_token: true
      )

      # Create a user
      user = User.create!(first_name: 'John', last_name: 'Doe', email: 'john@example.com')

      # Verify token columns contain tokens
      expect(user.first_name_token).to eq('token_for_John')
      expect(user.last_name_token).to eq('token_for_Doe')
      expect(user.email_token).to eq('token_for_john@example.com')

      # Verify original fields also contain values
      expect(user.read_attribute(:first_name)).to eq('John')
      expect(user.read_attribute(:last_name)).to eq('Doe')
      expect(user.read_attribute(:email)).to eq('john@example.com')

      # Verify accessor methods return values
      expect(user.first_name).to eq('John')
      expect(user.last_name).to eq('Doe')
      expect(user.email).to eq('john@example.com')
    end

    it 'handles setting fields to nil correctly' do
      # Configure User model
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { record.id.to_s },
        dual_write: false,
        read_from_token: true
      )

      # Reset all mocks to ensure clean state
      RSpec::Mocks.space.reset_all

      # Set up the encryption service mock again
      encryption_service = instance_double(PiiTokenizer::EncryptionService)
      allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)

      # Mock encrypt_batch
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Mock decrypt_batch to return nil for non-existent tokens
      allow(encryption_service).to receive(:decrypt_batch) do |tokens|
        result = {}
        tokens = [tokens] unless tokens.is_a?(Array)

        tokens.each do |token|
          if token.to_s.start_with?('token_for_')
            original_value = token.to_s.sub('token_for_', '')
            result[token] = original_value
          end
        end
        result
      end

      # Mock search_tokens
      allow(encryption_service).to receive(:search_tokens) do |value|
        ["token_for_#{value}"]
      end

      # Create a user
      user = User.create!(first_name: 'John', last_name: 'Doe')

      # Verify initial state
      expect(user.first_name_token).to eq('token_for_John')
      expect(user.first_name).to eq('John')

      # Now set to nil and save
      user.first_name = nil
      user.save!

      # Force a reload to ensure we get the latest database values
      user.reload

      # Verify token column was cleared
      expect(user.first_name_token).to be_nil

      # Verify accessor returns nil
      expect(user.first_name).to be_nil
    end
  end
end
