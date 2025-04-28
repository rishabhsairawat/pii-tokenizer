require 'spec_helper'

RSpec.describe 'PiiTokenizer Configuration Combinations', :use_tokenizable_models do
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

  # Helper methods to set configurations
  def with_config(dual_write:, read_from_token:)
    original_dual_write = User.dual_write_enabled
    original_read_from_token = User.read_from_token_column

    User.dual_write_enabled = dual_write
    User.read_from_token_column = read_from_token

    yield
  ensure
    User.dual_write_enabled = original_dual_write
    User.read_from_token_column = original_read_from_token
  end

  # Configuration 1: dual_write=true, read_from_token=false
  describe 'dual_write=true, read_from_token=false' do
    it 'correctly populates both columns when using new+save' do
      with_config(dual_write: true, read_from_token: false) do
        # Create a user with new then save
        user = User.new(first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')
        user.save!

        # Reload to ensure DB state is reflected
        user.reload

        # Both original and token columns should have values
        expect(user.read_attribute(:first_name)).to eq('John')
        expect(user.read_attribute(:last_name)).to eq('Doe')
        expect(user.read_attribute(:email)).to eq('john.doe@example.com')

        expect(user.read_attribute(:first_name_token)).to eq('token_for_John')
        expect(user.read_attribute(:last_name_token)).to eq('token_for_Doe')
        expect(user.read_attribute(:email_token)).to eq('token_for_john.doe@example.com')

        # Accessors should return original values
        expect(user.first_name).to eq('John')
        expect(user.last_name).to eq('Doe')
        expect(user.email).to eq('john.doe@example.com')
      end
    end

    it 'correctly populates both columns when using create' do
      with_config(dual_write: true, read_from_token: false) do
        # Create a user with create method
        user = User.create!(first_name: 'Alice', last_name: 'Smith', email: 'alice@example.com')

        # Reload to ensure DB state is reflected
        user.reload

        # Both original and token columns should have values
        expect(user.read_attribute(:first_name)).to eq('Alice')
        expect(user.read_attribute(:last_name)).to eq('Smith')
        expect(user.read_attribute(:email)).to eq('alice@example.com')

        expect(user.read_attribute(:first_name_token)).to eq('token_for_Alice')
        expect(user.read_attribute(:last_name_token)).to eq('token_for_Smith')
        expect(user.read_attribute(:email_token)).to eq('token_for_alice@example.com')

        # Accessors should return original values
        expect(user.first_name).to eq('Alice')
        expect(user.last_name).to eq('Smith')
        expect(user.email).to eq('alice@example.com')
      end
    end

    it 'correctly handles find_or_initialize_by with tokenized field' do
      with_config(dual_write: true, read_from_token: false) do
        # First create a user to test search
        existing_user = User.create!(first_name: 'Bob', last_name: 'Johnson', email: 'bob@example.com')

        # Query for existing user should use original column
        found_user = User.find_or_initialize_by(first_name: 'Bob')

        # Should find the existing user
        expect(found_user.id).to eq(existing_user.id)
        expect(found_user.first_name).to eq('Bob')
        expect(found_user.last_name).to eq('Johnson')
        expect(found_user).to be_persisted

        # Query for non-existing user
        new_user = User.find_or_initialize_by(first_name: 'Charlie')

        # Should initialize a new user
        expect(new_user.first_name).to eq('Charlie')
        expect(new_user).not_to be_persisted

        # Save the new user
        new_user.last_name = 'Brown'
        new_user.email = 'charlie@example.com'
        new_user.save!

        # Reload to ensure DB state is reflected
        new_user.reload

        # Both original and token columns should have values
        expect(new_user.read_attribute(:first_name)).to eq('Charlie')
        expect(new_user.read_attribute(:last_name)).to eq('Brown')
        expect(new_user.read_attribute(:email)).to eq('charlie@example.com')

        expect(new_user.read_attribute(:first_name_token)).to eq('token_for_Charlie')
        expect(new_user.read_attribute(:last_name_token)).to eq('token_for_Brown')
        expect(new_user.read_attribute(:email_token)).to eq('token_for_charlie@example.com')
      end
    end

    it 'correctly updates both columns when updating non-nil value' do
      with_config(dual_write: true, read_from_token: false) do
        # Create a user to update
        user = User.create!(first_name: 'David', last_name: 'Wilson', email: 'david@example.com')

        # Find the user by tokenized field
        found_user = User.find_by(first_name: 'David')
        expect(found_user.id).to eq(user.id)

        # Update a tokenized field
        found_user.email = 'david.new@example.com'
        found_user.save!

        # Reload to ensure DB state is reflected
        found_user.reload

        # Both original and token columns should be updated
        expect(found_user.read_attribute(:email)).to eq('david.new@example.com')
        expect(found_user.read_attribute(:email_token)).to eq('token_for_david.new@example.com')

        # Other fields should remain unchanged
        expect(found_user.read_attribute(:first_name)).to eq('David')
        expect(found_user.read_attribute(:first_name_token)).to eq('token_for_David')
      end
    end

    it 'correctly updates both columns when setting value to nil' do
      with_config(dual_write: true, read_from_token: false) do
        # Create a user to update
        user = User.create!(first_name: 'Eva', last_name: 'Brooks', email: 'eva@example.com')

        # Find the user using where
        found_user = User.where(last_name: 'Brooks').first
        expect(found_user.id).to eq(user.id)

        # Update a tokenized field to nil
        found_user.email = nil
        found_user.save!

        # Reload to ensure DB state is reflected
        found_user.reload

        # Both original and token columns should be nil
        expect(found_user.read_attribute(:email)).to be_nil
        expect(found_user.read_attribute(:email_token)).to be_nil

        # Accessor should return nil
        expect(found_user.email).to be_nil

        # Other fields should remain unchanged
        expect(found_user.read_attribute(:first_name)).to eq('Eva')
        expect(found_user.read_attribute(:first_name_token)).to eq('token_for_Eva')
      end
    end
  end

  # Configuration 2: dual_write=true, read_from_token=true
  describe 'dual_write=true, read_from_token=true' do
    it 'correctly populates both columns when using new+save' do
      with_config(dual_write: true, read_from_token: true) do
        # Create a user with new then save
        user = User.new(first_name: 'Frank', last_name: 'Thomas', email: 'frank@example.com')
        user.save!

        # Reload to ensure DB state is reflected
        user.reload

        # Both original and token columns should have values
        expect(user.read_attribute(:first_name)).to eq('Frank')
        expect(user.read_attribute(:last_name)).to eq('Thomas')
        expect(user.read_attribute(:email)).to eq('frank@example.com')

        expect(user.read_attribute(:first_name_token)).to eq('token_for_Frank')
        expect(user.read_attribute(:last_name_token)).to eq('token_for_Thomas')
        expect(user.read_attribute(:email_token)).to eq('token_for_frank@example.com')

        # Accessors should return original values
        expect(user.first_name).to eq('Frank')
        expect(user.last_name).to eq('Thomas')
        expect(user.email).to eq('frank@example.com')
      end
    end

    it 'correctly populates both columns when using create' do
      with_config(dual_write: true, read_from_token: true) do
        # Create a user with create method
        user = User.create!(first_name: 'Grace', last_name: 'Lee', email: 'grace@example.com')

        # Reload to ensure DB state is reflected
        user.reload

        # Both original and token columns should have values
        expect(user.read_attribute(:first_name)).to eq('Grace')
        expect(user.read_attribute(:last_name)).to eq('Lee')
        expect(user.read_attribute(:email)).to eq('grace@example.com')

        expect(user.read_attribute(:first_name_token)).to eq('token_for_Grace')
        expect(user.read_attribute(:last_name_token)).to eq('token_for_Lee')
        expect(user.read_attribute(:email_token)).to eq('token_for_grace@example.com')

        # Accessors should return original values
        expect(user.first_name).to eq('Grace')
        expect(user.last_name).to eq('Lee')
        expect(user.email).to eq('grace@example.com')
      end
    end

    it 'correctly handles find_or_initialize_by with tokenized field' do
      with_config(dual_write: true, read_from_token: true) do
        # First create a user to test search
        existing_user = User.create!(first_name: 'Henry', last_name: 'Miller', email: 'henry@example.com')

        # Query for existing user should use token column
        found_user = User.find_or_initialize_by(first_name: 'Henry')

        # Should find the existing user
        expect(found_user.id).to eq(existing_user.id)
        expect(found_user.first_name).to eq('Henry')
        expect(found_user.last_name).to eq('Miller')
        expect(found_user).to be_persisted

        # Query for non-existing user
        new_user = User.find_or_initialize_by(first_name: 'Isabella')

        # Should initialize a new user
        expect(new_user.first_name).to eq('Isabella')
        expect(new_user).not_to be_persisted

        # Save the new user
        new_user.last_name = 'Garcia'
        new_user.email = 'isabella@example.com'
        new_user.save!

        # Reload to ensure DB state is reflected
        new_user.reload

        # Both original and token columns should have values
        expect(new_user.read_attribute(:first_name)).to eq('Isabella')
        expect(new_user.read_attribute(:last_name)).to eq('Garcia')
        expect(new_user.read_attribute(:email)).to eq('isabella@example.com')

        expect(new_user.read_attribute(:first_name_token)).to eq('token_for_Isabella')
        expect(new_user.read_attribute(:last_name_token)).to eq('token_for_Garcia')
        expect(new_user.read_attribute(:email_token)).to eq('token_for_isabella@example.com')
      end
    end

    it 'correctly updates both columns when updating non-nil value' do
      with_config(dual_write: true, read_from_token: true) do
        # Create a user to update
        user = User.create!(first_name: 'James', last_name: 'Anderson', email: 'james@example.com')

        # Find the user by tokenized field
        found_user = User.find_by(first_name: 'James')
        expect(found_user.id).to eq(user.id)

        # Update a tokenized field
        found_user.email = 'james.new@example.com'
        found_user.save!

        # Reload to ensure DB state is reflected
        found_user.reload

        # Both original and token columns should be updated
        expect(found_user.read_attribute(:email)).to eq('james.new@example.com')
        expect(found_user.read_attribute(:email_token)).to eq('token_for_james.new@example.com')

        # Other fields should remain unchanged
        expect(found_user.read_attribute(:first_name)).to eq('James')
        expect(found_user.read_attribute(:first_name_token)).to eq('token_for_James')
      end
    end

    it 'correctly updates both columns when setting value to nil' do
      with_config(dual_write: true, read_from_token: true) do
        # Create a user to update
        user = User.create!(first_name: 'Kate', last_name: 'Wilson', email: 'kate@example.com')

        # Find the user using where
        found_user = User.find_by(last_name: 'Wilson')
        expect(found_user.id).to eq(user.id)

        # Update a tokenized field to nil
        found_user.email = nil
        found_user.save!

        # Reload to ensure DB state is reflected
        found_user.reload

        # Both original and token columns should be nil
        expect(found_user.read_attribute(:email)).to be_nil
        expect(found_user.read_attribute(:email_token)).to be_nil

        # Accessor should return nil
        expect(found_user.email).to be_nil

        # Other fields should remain unchanged
        expect(found_user.read_attribute(:first_name)).to eq('Kate')
        expect(found_user.read_attribute(:first_name_token)).to eq('token_for_Kate')
      end
    end
  end

  # Configuration 3: dual_write=false, read_from_token=true
  describe 'dual_write=false, read_from_token=true' do
    it 'correctly populates only token columns when using new+save' do
      with_config(dual_write: false, read_from_token: true) do
        # Create a user with new then save
        user = User.new(first_name: 'Luke', last_name: 'Brown', email: 'luke@example.com')
        user.save!

        # Reload to ensure DB state is reflected
        user.reload

        # Original columns should be nil
        expect(user.read_attribute(:first_name)).to be_nil
        expect(user.read_attribute(:last_name)).to be_nil
        expect(user.read_attribute(:email)).to be_nil

        # Token columns should have values
        expect(user.read_attribute(:first_name_token)).to eq('token_for_Luke')
        expect(user.read_attribute(:last_name_token)).to eq('token_for_Brown')
        expect(user.read_attribute(:email_token)).to eq('token_for_luke@example.com')

        # Accessors should return decrypted values
        expect(user.first_name).to eq('Luke')
        expect(user.last_name).to eq('Brown')
        expect(user.email).to eq('luke@example.com')
      end
    end

    it 'correctly populates only token columns when using create' do
      with_config(dual_write: false, read_from_token: true) do
        # Create a user with create method
        user = User.create!(first_name: 'Mia', last_name: 'Davis', email: 'mia@example.com')

        # Reload to ensure DB state is reflected
        user.reload

        # Original columns should be nil
        expect(user.read_attribute(:first_name)).to be_nil
        expect(user.read_attribute(:last_name)).to be_nil
        expect(user.read_attribute(:email)).to be_nil

        # Token columns should have values
        expect(user.read_attribute(:first_name_token)).to eq('token_for_Mia')
        expect(user.read_attribute(:last_name_token)).to eq('token_for_Davis')
        expect(user.read_attribute(:email_token)).to eq('token_for_mia@example.com')

        # Accessors should return decrypted values
        expect(user.first_name).to eq('Mia')
        expect(user.last_name).to eq('Davis')
        expect(user.email).to eq('mia@example.com')
      end
    end

    it 'correctly handles find_or_initialize_by with tokenized field' do
      with_config(dual_write: false, read_from_token: true) do
        # First create a user to test search
        existing_user = User.create!(first_name: 'Noah', last_name: 'Wilson', email: 'noah@example.com')

        # Query for existing user should use token column
        found_user = User.find_or_initialize_by(first_name: 'Noah')

        # Should find the existing user
        expect(found_user.id).to eq(existing_user.id)
        expect(found_user.first_name).to eq('Noah')
        expect(found_user.last_name).to eq('Wilson')
        expect(found_user).to be_persisted

        # Query for non-existing user
        new_user = User.find_or_initialize_by(first_name: 'Olivia')

        # Should initialize a new user
        expect(new_user.first_name).to eq('Olivia')
        expect(new_user).not_to be_persisted

        # Save the new user
        new_user.last_name = 'Martinez'
        new_user.email = 'olivia@example.com'
        new_user.save!

        # Reload to ensure DB state is reflected
        new_user.reload

        # Original columns should be nil
        expect(new_user.read_attribute(:first_name)).to be_nil
        expect(new_user.read_attribute(:last_name)).to be_nil
        expect(new_user.read_attribute(:email)).to be_nil

        # Token columns should have values
        expect(new_user.read_attribute(:first_name_token)).to eq('token_for_Olivia')
        expect(new_user.read_attribute(:last_name_token)).to eq('token_for_Martinez')
        expect(new_user.read_attribute(:email_token)).to eq('token_for_olivia@example.com')
      end
    end

    it 'correctly updates only token columns when updating non-nil value' do
      with_config(dual_write: false, read_from_token: true) do
        # Create a user to update
        user = User.create!(first_name: 'Peter', last_name: 'Harris', email: 'peter@example.com')

        # Find the user by tokenized field
        found_user = User.find_by(first_name: 'Peter')
        expect(found_user.id).to eq(user.id)

        # Update a tokenized field
        found_user.email = 'peter.new@example.com'
        found_user.save!

        # Reload to ensure DB state is reflected
        found_user.reload

        # Original column should be nil
        expect(found_user.read_attribute(:email)).to be_nil

        # Token column should be updated
        expect(found_user.read_attribute(:email_token)).to eq('token_for_peter.new@example.com')

        # Accessor should return decrypted value
        expect(found_user.email).to eq('peter.new@example.com')

        # Other fields should remain unchanged in their respective columns
        expect(found_user.read_attribute(:first_name)).to be_nil
        expect(found_user.read_attribute(:first_name_token)).to eq('token_for_Peter')
      end
    end

    it 'correctly updates only token columns when setting value to nil' do
      with_config(dual_write: false, read_from_token: true) do
        # Create a user to update
        user = User.create!(first_name: 'Ryan', last_name: 'Taylor', email: 'ryan@example.com')

        # Find the user using where
        found_user = User.where(last_name: 'Taylor').first
        expect(found_user.id).to eq(user.id)

        # Update a tokenized field to nil
        found_user.email = nil
        found_user.save!

        # Reload to ensure DB state is reflected
        found_user.reload

        # Original column should already be nil
        expect(found_user.read_attribute(:email)).to be_nil

        # Token column should be set to nil
        expect(found_user.read_attribute(:email_token)).to be_nil

        # Accessor should return nil
        expect(found_user.email).to be_nil

        # Other fields should remain unchanged in their respective columns
        expect(found_user.read_attribute(:first_name)).to be_nil
        expect(found_user.read_attribute(:first_name_token)).to eq('token_for_Ryan')
      end
    end
  end
end
