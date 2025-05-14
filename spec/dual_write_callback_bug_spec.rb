require 'spec_helper'

RSpec.describe 'PiiTokenizer DualWrite with Callbacks' do
  # Define a test model with a callback that populates a field
  class UserWithCallback < User
    attr_accessor :callback_called

    # Callback that populates name if it's nil
    before_save :populate_name

    def populate_name
      # Track that the callback was called
      self.callback_called = true

      # If name is nil, populate it from email
      if first_name.nil? && email.present?
        self.first_name = email.split('@').first
      end
    end
  end

  let(:encryption_service) { instance_double('PiiTokenizer::EncryptionService') }

  before do
    # Clear existing users
    User.delete_all

    # Configure UserWithCallback with dual_write=true
    UserWithCallback.tokenize_pii(
      fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
      entity_type: 'user_uuid',
      entity_id: ->(record) { record.id.to_s },
      dual_write: true,
      read_from_token: false
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
  end

  after do
    # Clean up our test model
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
  end

  describe 'field population in callbacks' do
    it 'correctly tokenizes a field populated in a callback after being set to nil' do
      # Create a user with a first name and email
      user = UserWithCallback.create!(
        id: 1,
        first_name: 'ami_chopra2004',
        last_name: 'Doe',
        email: 'ami_chopra2004@example.com'
      )

      # Verify initial state
      expect(user.first_name).to eq('ami_chopra2004')
      expect(user.first_name_token).to eq('token_for_ami_chopra2004')
      expect(user.read_attribute(:first_name)).to eq('ami_chopra2004')

      # Reset the user and set up for testing our scenario
      user = UserWithCallback.find(1)

      # Now set first_name to nil, which should trigger the callback
      user.first_name = nil
      user.save!

      # Reload the user to see the final database state
      user.reload

      # Verify callback was called
      expect(user.callback_called).to be true

      # Verify that the first_name field was populated from email
      expect(user.read_attribute(:first_name)).to eq('ami_chopra2004')

      # Verify the token was properly generated
      expect(user.first_name_token).not_to be_nil
      expect(user.first_name_token).to eq('token_for_ami_chopra2004')

      # The accessor returns the correct value
      expect(user.first_name).to eq('ami_chopra2004')
    end
  end
end
