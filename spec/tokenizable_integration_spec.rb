require 'spec_helper'

RSpec.describe PiiTokenizer::Tokenizable, :use_tokenizable_models do
  # Only mock the encryption service (external dependency)
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    # Clear the database before each test
    User.delete_all

    # Mock the encryption service
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)

    # Set up the encryption service to return deterministic tokens
    allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
      result = {}
      tokens_data.each do |data|
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
        result[key] = "token_for_#{data[:value]}"
      end
      result
    end

    # Set up decryption service to return original values
    allow(encryption_service).to receive(:decrypt_batch) do |tokens|
      result = {}
      tokens.each do |token|
        if token.start_with?('token_for_')
          original_value = token.sub('token_for_', '')
          result[token] = original_value
        end
      end
      result
    end

    # Set up token search
    allow(encryption_service).to receive(:search_tokens) do |value|
      ["token_for_#{value}"]
    end
  end

  # Helper methods for configuration
  def with_dual_write(value)
    original_setting = User.dual_write_enabled
    User.dual_write_enabled = value
    yield
  ensure
    User.dual_write_enabled = original_setting
  end

  def with_read_from_token(value)
    original_setting = User.read_from_token_column
    User.read_from_token_column = value
    yield
  ensure
    User.read_from_token_column = original_setting
  end

  describe 'basic tokenization' do
    it 'encrypts PII fields when saving a new record' do
      # Create and save a user
      user = User.create(
        first_name: 'Jane',
        last_name: 'Doe',
        email: 'jane.doe@example.com'
      )

      # Reload to ensure values are persisted
      user.reload

      # Check token fields
      expect(user.first_name_token).to eq('token_for_Jane')
      expect(user.last_name_token).to eq('token_for_Doe')
      expect(user.email_token).to eq('token_for_jane.doe@example.com')

      # Check original fields with default config (dual_write=false)
      expect(user.read_attribute(:first_name)).to be_nil
      expect(user.read_attribute(:last_name)).to be_nil
      expect(user.read_attribute(:email)).to be_nil

      # But accessors should still work
      expect(user.first_name).to eq('Jane')
      expect(user.last_name).to eq('Doe')
      expect(user.email).to eq('jane.doe@example.com')
    end

    it 'encrypts PII fields when updating an existing record' do
      # Create and save a user
      user = User.create(
        first_name: 'Jane',
        last_name: 'Doe',
        email: 'jane.doe@example.com'
      )

      # Update a field
      user.update(first_name: 'Janet')

      # Reload to ensure values are persisted
      user.reload

      # First name token should be updated
      expect(user.first_name_token).to eq('token_for_Janet')

      # Other tokens should remain unchanged
      expect(user.last_name_token).to eq('token_for_Doe')
      expect(user.email_token).to eq('token_for_jane.doe@example.com')

      # Accessor should return updated value
      expect(user.first_name).to eq('Janet')
    end

    it 'clears tokens when setting fields to nil' do
      # Create and save a user
      user = User.create(
        first_name: 'Jane',
        last_name: 'Doe',
        email: 'jane.doe@example.com'
      )

      # Set a field to nil
      user.update(email: nil)

      # Reload to ensure values are persisted
      user.reload

      # Email token should be nil
      expect(user.email_token).to be_nil

      # Email accessor should return nil
      expect(user.email).to be_nil

      # Other tokens should remain unchanged
      expect(user.first_name_token).to eq('token_for_Jane')
      expect(user.last_name_token).to eq('token_for_Doe')
    end
  end

  describe 'dual write mode' do
    it 'preserves original fields when dual_write is enabled' do
      with_dual_write(true) do
        # Create and save a user
        user = User.create(
          first_name: 'John',
          last_name: 'Smith',
          email: 'john.smith@example.com'
        )

        # Reload to ensure values are persisted
        user.reload

        # Check token fields
        expect(user.first_name_token).to eq('token_for_John')
        expect(user.last_name_token).to eq('token_for_Smith')
        expect(user.email_token).to eq('token_for_john.smith@example.com')

        # Check original fields are preserved
        expect(user.read_attribute(:first_name)).to eq('John')
        expect(user.read_attribute(:last_name)).to eq('Smith')
        expect(user.read_attribute(:email)).to eq('john.smith@example.com')
      end
    end

    it 'clears original fields when dual_write is disabled' do
      with_dual_write(false) do
        # Create and save a user
        user = User.create(
          first_name: 'John',
          last_name: 'Smith',
          email: 'john.smith@example.com'
        )

        # Reload to ensure values are persisted
        user.reload

        # Check token fields
        expect(user.first_name_token).to eq('token_for_John')
        expect(user.last_name_token).to eq('token_for_Smith')
        expect(user.email_token).to eq('token_for_john.smith@example.com')

        # Check original fields are cleared
        expect(user.read_attribute(:first_name)).to be_nil
        expect(user.read_attribute(:last_name)).to be_nil
        expect(user.read_attribute(:email)).to be_nil

        # But accessors still work
        expect(user.first_name).to eq('John')
        expect(user.last_name).to eq('Smith')
        expect(user.email).to eq('john.smith@example.com')
      end
    end

    it 'updates both original and token fields when dual_write is enabled' do
      with_dual_write(true) do
        # Create and save a user
        user = User.create(
          first_name: 'John',
          last_name: 'Smith',
          email: 'john.smith@example.com'
        )

        # Update a field
        user.update(email: 'john.updated@example.com')

        # Reload to ensure values are persisted
        user.reload

        # Check token is updated
        expect(user.email_token).to eq('token_for_john.updated@example.com')

        # Check original field is updated
        expect(user.read_attribute(:email)).to eq('john.updated@example.com')
      end
    end
  end

  describe 'read from token mode' do
    it 'finds records by PII fields when read_from_token is enabled' do
      # Create a user
      user = User.create(
        first_name: 'Robert',
        last_name: 'Jones',
        email: 'robert.jones@example.com'
      )

      # Should be able to find by original field name
      found_user = User.find_by(first_name: 'Robert')
      expect(found_user).to eq(user)

      # Should be able to use where
      found_users = User.where(last_name: 'Jones')
      expect(found_users).to include(user)
    end

    it 'finds records by original fields when read_from_token is disabled' do
      with_read_from_token(false) do
        # With dual write enabled, we need original fields for querying
        with_dual_write(true) do
          # Create a user
          user = User.create(
            first_name: 'Robert',
            last_name: 'Jones',
            email: 'robert.jones@example.com'
          )

          # Should be able to find by original field name
          found_user = User.find_by(first_name: 'Robert')
          expect(found_user).to eq(user)

          # Should be able to use where
          found_users = User.where(last_name: 'Jones')
          expect(found_users).to include(user)
        end
      end
    end
  end

  describe 'skipping unchanged fields' do
    # Create a test user once for all tests
    let!(:user) do
      User.create(
        first_name: 'Jane',
        last_name: 'Doe',
        email: 'jane.doe@example.com'
      )
    end

    # Reset expectations for each test
    before do
      # Reload the user to ensure a clean state
      user.reload

      # Reset encryption service mock
      allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end
      allow(encryption_service).to receive(:decrypt_batch) do |tokens|
        result = {}
        tokens.each do |token|
          if token.start_with?('token_for_')
            original_value = token.sub('token_for_', '')
            result[token] = original_value
          end
        end
        result
      end
      allow(encryption_service).to receive(:search_tokens) do |value|
        ["token_for_#{value}"]
      end
    end

    it 'updates token when field is changed' do
      # Initial token should match initial value
      expect(user.first_name_token).to eq('token_for_Jane')

      # Update the field
      user.update(first_name: 'Janet')

      # Reload to ensure persistence
      user.reload

      # Token should be updated
      expect(user.first_name_token).to eq('token_for_Janet')
    end

    it 'clears token when field is set to nil' do
      # Set field to nil
      user.update(email: nil)

      # Reload to ensure persistence
      user.reload

      # Token should be nil
      expect(user.email_token).to be_nil
      expect(user.email).to be_nil
    end

    it 'sets token when updating field that was previously nil' do
      # Create a new user with nil email
      test_user = User.new(
        id: 54_321,
        first_name: 'Special',
        last_name: 'Test'
        # email is intentionally nil
      )

      # Track attribute writes
      written_attributes = {}
      allow(test_user).to receive(:safe_write_attribute) do |attr, value|
        written_attributes[attr] = value
      end

      # Allow reading attributes with helper method
      allow(test_user).to receive(:read_attribute) do |attr|
        if attr.to_s.end_with?('_token')
          written_attributes[attr.to_s]
        else
          case attr.to_s
          when 'first_name' then 'Special'
          when 'last_name' then 'Test'
          when 'email' then nil # Initially nil
          end
        end
      end

      # Setup as persisted
      allow(test_user).to receive(:persisted?).and_return(true)
      allow(test_user).to receive(:new_record?).and_return(false)
      allow(test_user).to receive(:field_decryption_cache).and_return({})

      # Mock DB access
      allow(User).to receive(:unscoped).and_return(User)
      allow(User).to receive(:where).and_return(User)
      allow(User).to receive(:update_all).and_return(true)

      # Setup encryption service
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # First, encrypt the initial fields
      test_user.send(:encrypt_pii_fields)

      # Verify the initial tokens
      expect(written_attributes['first_name_token']).to eq('token_for_Special')
      expect(written_attributes['last_name_token']).to eq('token_for_Test')
      expect(written_attributes['email_token']).to be_nil

      # Now "update" the email field
      # 1. Set the instance variable
      test_user.instance_variable_set('@original_email', 'special@example.com')

      # 2. Update the read_attribute mock to return the new email
      allow(test_user).to receive(:read_attribute) do |attr|
        if attr.to_s.end_with?('_token')
          written_attributes[attr.to_s]
        else
          case attr.to_s
          when 'first_name' then 'Special'
          when 'last_name' then 'Test'
          when 'email' then 'special@example.com' # Now has a value
          end
        end
      end

      # 3. Mock the changes hash
      allow(test_user).to receive(:changes).and_return({ 'email' => [nil, 'special@example.com'] })

      # Run the encrypt fields again
      test_user.send(:encrypt_pii_fields)

      # Verify the email token was set
      expect(written_attributes['email_token']).to eq('token_for_special@example.com')
    end

    it "doesn't change tokens for fields that aren't updated" do
      # Get original token values
      original_first_name_token = user.first_name_token
      original_last_name_token = user.last_name_token

      # Update only email
      user.update(email: 'jane.updated@example.com')
      user.reload

      # First name and last name tokens should remain unchanged
      expect(user.first_name_token).to eq(original_first_name_token)
      expect(user.last_name_token).to eq(original_last_name_token)

      # Email token should be updated
      expect(user.email_token).to eq('token_for_jane.updated@example.com')
    end
  end

  describe 'finding or creating records' do
    it 'can find_or_create_by tokenized fields' do
      # Create initial user
      User.create(
        first_name: 'James',
        last_name: 'Wilson',
        email: 'james.wilson@example.com'
      )

      # Should find existing user
      user1 = User.find_or_create_by(first_name: 'James')
      expect(user1.first_name).to eq('James')
      expect(user1.last_name).to eq('Wilson')

      # Should create new user
      user2 = User.find_or_create_by(first_name: 'David')
      expect(user2.first_name).to eq('David')
      expect(user2.id).not_to eq(user1.id)
    end

    it 'can find_or_initialize_by tokenized fields' do
      # Create initial user
      User.create(
        first_name: 'Sarah',
        last_name: 'Johnson',
        email: 'sarah.johnson@example.com'
      )

      # Should find existing user
      user1 = User.find_or_initialize_by(first_name: 'Sarah')
      expect(user1.first_name).to eq('Sarah')
      expect(user1.last_name).to eq('Johnson')
      expect(user1).to be_persisted

      # Should initialize new user but not save
      user2 = User.find_or_initialize_by(first_name: 'Michael')
      expect(user2.first_name).to eq('Michael')
      expect(user2).not_to be_persisted
    end
  end

  describe 'batch decryption' do
    it 'can preload decrypted fields for multiple records' do
      # Create test users
      user1 = User.create(first_name: 'User1', last_name: 'Test')
      user2 = User.create(first_name: 'User2', last_name: 'Test')
      user3 = User.create(first_name: 'User3', last_name: 'Test')

      # Should make a single decrypt_batch call
      expect(encryption_service).to receive(:decrypt_batch) do |tokens|
        # Should contain all first_name tokens
        expect(tokens).to include('token_for_User1', 'token_for_User2', 'token_for_User3')

        # Return decrypted values
        {
          'token_for_User1' => 'User1',
          'token_for_User2' => 'User2',
          'token_for_User3' => 'User3'
        }
      end

      # Use include_decrypted_fields to preload all first_name values
      users = User.where(last_name: 'Test').include_decrypted_fields(:first_name).to_a

      # All users should have their first_name values available without additional calls
      expect(users.map(&:first_name)).to contain_exactly('User1', 'User2', 'User3')
    end
  end

  describe 'with dropped columns and dual_write off' do
    before do
      # Create a test table with only token columns
      ActiveRecord::Migration.create_table :test_users do |t|
        t.string :email_token
        t.string :phone_token
      end

      # Define the test model
      class TestUser < ActiveRecord::Base
        include PiiTokenizer::Tokenizable
        tokenize_pii fields: [:email, :phone],
                    entity_type: 'user_uuid',
                    entity_id: ->(user) { "#{user.id}" },
                    dual_write: false
      end
    end

    after do
      # Clean up the test table
      ActiveRecord::Migration.drop_table :test_users
    end

    it 'should create record with tokenized fields when original column is dropped' do
      # Create a record with tokenized fields
      user = TestUser.create(email: "test@example.com", phone: "1234567890")
      
      # Verify the record was created successfully
      expect(user).to be_persisted
      
      # Verify the token columns were populated
      expect(user.email_token).to be_present
      expect(user.phone_token).to be_present
      
      # Verify we can find the record by the tokenized fields
      found_user = TestUser.find_by(email: "test@example.com")
      expect(found_user.id).to eq(user.id)
    end
  end
end
