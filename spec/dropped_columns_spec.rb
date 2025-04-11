require 'spec_helper'

RSpec.describe 'PiiTokenizer with Dropped Columns' do
  let(:encryption_service) { instance_double('PiiTokenizer::EncryptionService') }

  # Define a user class that simulates dropped columns
  class UserWithDroppedColumns < ActiveRecord::Base
    self.table_name = 'users'
    
    include PiiTokenizer::Tokenizable
    
    # Override column_exists? to simulate dropped columns
    def self.column_exists?(field)
      ![:first_name, :last_name].include?(field.to_sym)
    end
    
    # Define tokenization with fields that "don't exist" in the database
    tokenize_pii(
      fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
      entity_type: 'customer',
      entity_id: ->(record) { "User_customer_#{record.id}" },
      dual_write: false
    )
  end
  
  before do
    # Clear existing users
    User.delete_all
    
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
  
  describe 'when columns are dropped' do
    it 'can read values from token columns' do
      # Create a user with the original User class 
      # (which has all columns in the database)
      user = User.create!(
        first_name: 'John',
        last_name: 'Doe',
        email: 'john@example.com'
      )
      
      # Reload the record into our special class that simulates dropped columns
      user_with_dropped = UserWithDroppedColumns.find(user.id)
      
      # Should be able to read values even though columns are "dropped"
      expect(user_with_dropped.first_name).to eq('John')
      expect(user_with_dropped.last_name).to eq('Doe')
      expect(user_with_dropped.email).to eq('john@example.com')
    end
    
    it 'can update values for dropped columns' do
      # Create a user with the original User class
      user = User.create!(
        first_name: 'John',
        last_name: 'Doe',
        email: 'john@example.com'
      )
      
      # Load with our special class and update values
      user_with_dropped = UserWithDroppedColumns.find(user.id)
      user_with_dropped.first_name = 'Jane'
      user_with_dropped.save!
      
      # Reload to make sure it was saved to the database
      user_with_dropped = UserWithDroppedColumns.find(user.id)
      expect(user_with_dropped.first_name).to eq('Jane')
      
      # The original column should be untouched (nil) but token updated
      original_user = User.find(user.id)
      expect(original_user.read_attribute(:first_name)).to be_nil
      expect(original_user.first_name_token).to eq('token_for_Jane')
    end
    
    it 'can set dropped column values to nil' do
      # Create a user with the original User class
      user = User.create!(
        first_name: 'John',
        last_name: 'Doe',
        email: 'john@example.com'
      )
      
      # Load with our special class and set value to nil
      user_with_dropped = UserWithDroppedColumns.find(user.id)
      user_with_dropped.first_name = nil
      user_with_dropped.save!
      
      # Reload to make sure it was saved
      user_with_dropped = UserWithDroppedColumns.find(user.id)
      expect(user_with_dropped.first_name).to be_nil
      
      # The token column should be nil too
      original_user = User.find(user.id)
      expect(original_user.first_name_token).to be_nil
    end
    
    it 'supports creating new records with values for dropped columns' do
      # Create directly with the class that simulates dropped columns
      user = UserWithDroppedColumns.new(
        first_name: 'Alice',
        last_name: 'Smith',
        email: 'alice@example.com'
      )
      
      # Should save without error
      expect { user.save! }.not_to raise_error
      
      # Reload to verify it saved correctly
      user = UserWithDroppedColumns.find(user.id)
      expect(user.first_name).to eq('Alice')
      expect(user.last_name).to eq('Smith')
      expect(user.email).to eq('alice@example.com')
      
      # Original columns should be nil, token columns should have values
      original_user = User.find(user.id)
      expect(original_user.read_attribute(:first_name)).to be_nil
      expect(original_user.read_attribute(:last_name)).to be_nil
      expect(original_user.first_name_token).to eq('token_for_Alice')
      expect(original_user.last_name_token).to eq('token_for_Smith')
    end
    
    it 'can find records by tokenized fields with dropped columns' do
      # Create a few users
      User.create!(first_name: 'Alice', email: 'alice@example.com')
      User.create!(first_name: 'Bob', email: 'bob@example.com')
      User.create!(first_name: 'Charlie', email: 'charlie@example.com')
      
      # Search using the class with dropped columns
      result = UserWithDroppedColumns.find_by(first_name: 'Bob')
      
      # Should find the correct record
      expect(result).not_to be_nil
      expect(result.first_name).to eq('Bob')
      expect(result.email).to eq('bob@example.com')
    end
    
    it 'handles BatchOperations with dropped columns' do
      # Create a few users
      User.create!(first_name: 'Alice', last_name: 'Anderson', email: 'alice@example.com')
      User.create!(first_name: 'Bob', last_name: 'Brown', email: 'bob@example.com')
      User.create!(first_name: 'Charlie', last_name: 'Clark', email: 'charlie@example.com')
      
      # Use include_decrypted_fields with dropped columns
      results = UserWithDroppedColumns.include_decrypted_fields(:first_name, :last_name).all.to_a
      
      # Should preload all values correctly
      expect(results.size).to eq(3)
      expect(results.map(&:first_name)).to contain_exactly('Alice', 'Bob', 'Charlie')
      expect(results.map(&:last_name)).to contain_exactly('Anderson', 'Brown', 'Clark')
    end
  end
  
  describe 'virtual attribute behavior' do
    it 'stores values in virtual attributes before save' do
      # Create a new record with the class that simulates dropped columns
      user = UserWithDroppedColumns.new(first_name: 'Test')
      
      # Should store the value in a virtual attribute
      expect(user.instance_variable_get('@_virtual_first_name')).to eq('Test')
      
      # Should still be accessible via getter
      expect(user.first_name).to eq('Test')
      
      # Change the value
      user.first_name = 'Updated'
      
      # Should update the virtual attribute
      expect(user.instance_variable_get('@_virtual_first_name')).to eq('Updated')
      
      # Should be accessible via getter
      expect(user.first_name).to eq('Updated')
    end
    
    it 'properly saves virtual attributes to token columns' do
      # Create with virtual attributes
      user = UserWithDroppedColumns.new(
        first_name: 'Virtual',
        last_name: 'Attribute'
      )
      
      # Save to persist to database
      user.save!
      
      # Check that token columns got updated
      original_user = User.find(user.id)
      expect(original_user.first_name_token).to eq('token_for_Virtual')
      expect(original_user.last_name_token).to eq('token_for_Attribute')
    end
  end
  
  describe 'mixed column status' do
    it 'handles models with both existing and dropped columns' do
      # Create a user with the original User class first
      user = User.create!(
        first_name: 'Mixed',
        last_name: 'Columns',
        email: 'mixed@example.com'
      )
      
      # Now that we have tokens created, load with our special class
      user_with_dropped = UserWithDroppedColumns.find(user.id)
      
      # Mock the decrypt_batch method specifically for this test
      # to return the expected decrypted values
      allow(encryption_service).to receive(:decrypt_batch) do |tokens|
        result = {}
        tokens.each do |token|
          if token == "token_for_Mixed"
            result[token] = "Mixed"
          elsif token == "token_for_Columns"
            result[token] = "Columns"
          elsif token == "token_for_mixed@example.com"
            result[token] = "mixed@example.com"
          end
        end
        result
      end
      
      # Access the fields to trigger decryption
      expect(user_with_dropped.first_name).to eq('Mixed')
      expect(user_with_dropped.last_name).to eq('Columns')
      expect(user_with_dropped.email).to eq('mixed@example.com')
      
      # Make a change to a field with dropped column 
      user_with_dropped.first_name = 'Updated'
      user_with_dropped.save!
      
      # The original User should have updated the token
      original_user = User.find(user.id)
      expect(original_user.read_attribute(:first_name)).to be_nil
      expect(original_user.read_attribute(:last_name)).to be_nil
      expect(original_user.first_name_token).to eq('token_for_Updated')
      expect(original_user.last_name_token).to eq('token_for_Columns')
      
      # But since we're in dual_write: false mode, email might be nil in the database
      # (depending on implementation details)
      # We care more about the token value
      expect(original_user.email_token).to eq('token_for_mixed@example.com')
    end
  end
end 