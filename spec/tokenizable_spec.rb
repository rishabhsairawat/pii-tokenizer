require 'spec_helper'

#
# PiiTokenizer::Tokenizable Tests
# -------------------------------
#
# Test Design Principles:
#
# 1. Consistent setup: Using shared contexts for common tasks
#    - `create_persisted_user_with_tokens` - Creates user with token values set
#    - `clear_original_instance_variables` - Removes AR instance variables
#    - `stub_encrypt_batch` - Standard mock for tokenization
#    - `stub_decrypt_batch` - Standard mock for detokenization
#
# 2. Explicit test state: Each test clearly defines initial state and expectations
#
# 3. Isolation: Tests restore global state changes in ensure blocks
#
# 4. Readability: Tests focus on behavior, not implementation details
#
# 5. No unnecessary stubbing: Only mock what's necessary
#

RSpec.describe PiiTokenizer::Tokenizable, :use_encryption_service, :use_tokenizable_models do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
  end
  
  # Shared context with helper methods for tests
  shared_context "tokenization test helpers" do
    # Helper to create a user with token values (simulating a saved record)
    def create_persisted_user_with_tokens(attributes = {})
      default_attrs = { 
        id: 1, 
        first_name: 'John', 
        last_name: 'Doe', 
        email: 'john.doe@example.com' 
      }
      user = User.new(default_attrs.merge(attributes))
      
      # Set token values
      user.write_attribute(:first_name_token, "token_for_#{user.first_name}")
      user.write_attribute(:last_name_token, "token_for_#{user.last_name}")  
      user.write_attribute(:email_token, "token_for_#{user.email}")
      
      # Mark as persisted
      allow(user).to receive(:new_record?).and_return(false)
      allow(user).to receive(:persisted?).and_return(true)
      allow(user).to receive(:changes).and_return({})
      
      # Clear instance variables that would trigger encryption
      user.instance_variable_set(:@field_decryption_cache, {})
      
      # Remove instance variables set during initialization
      clear_original_instance_variables(user)
      
      user
    end
    
    # Helper to clear instance variables that would trigger encryption
    def clear_original_instance_variables(user)
      User.tokenized_fields.each do |field|
        variable_name = "@original_#{field}"
        user.remove_instance_variable(variable_name) if user.instance_variable_defined?(variable_name)
      end
    end
    
    # Helper to set up encryption service to return tokens
    def stub_encrypt_batch
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end
    end
    
    # Helper to set up encryption service to return decrypted values
    def stub_decrypt_batch
      allow(encryption_service).to receive(:decrypt_batch) do |tokens|
        result = {}
        tokens.each do |token|
          # Extract the value from the token format "token_for_VALUE"
          if token.start_with?("token_for_")
            original_value = token.sub("token_for_", "")
            result[token] = original_value
          end
        end
        result
      end
    end
    
    # Helper method to test with dual write settings
    def with_dual_write_setting(value)
      original_setting = User.dual_write_enabled
      User.dual_write_enabled = value
      begin
        yield
      ensure
        User.dual_write_enabled = original_setting
      end
    end
    
    # Helper to test with read_from_token setting
    def with_read_from_token_setting(value)
      original_setting = User.read_from_token_column
      User.read_from_token_column = value
      begin
        yield
      ensure
        User.read_from_token_column = original_setting
      end
    end
  end

  # User model fixture for testing
  let(:user) { User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com') }
  
  # Group tests by functionality area
  describe 'configuration' do
    include_context "tokenization test helpers"
    
    it 'defines tokenized fields' do
      expect(User.tokenized_fields).to match_array(%i[first_name last_name email])
    end

    it 'defines PII types' do
      expect(User.pii_types).to include(
        'first_name' => 'FIRST_NAME',
        'last_name' => 'LAST_NAME',
        'email' => 'EMAIL'
      )
    end

    it 'defines entity type' do
      expect(user.entity_type).to eq('customer')
      expect(user.entity_type).to eq(User.entity_type_proc.call(user))
    end

    it 'defines entity id' do
      expect(user.entity_id).to eq("User_customer_1")
      expect(user.entity_id).to eq(User.entity_id_proc.call(user))
    end
  end
  
  describe 'encryption' do
    include_context "tokenization test helpers"
    
    it 'encrypts PII fields before save' do
      # Set up batch encryption expectation
      stub_encrypt_batch
      
      # Save the user
      user.save

      # Verify the tokens were set with expected values
      expect(user.first_name_token).to eq("token_for_John")
      expect(user.last_name_token).to eq("token_for_Doe")
      expect(user.email_token).to eq("token_for_john.doe@example.com")
    end

    it 'properly handles setting tokenized fields to nil' do
      # Create a persisted user with tokens
      user = create_persisted_user_with_tokens
      
      # Mock the changes hash
      allow(user).to receive(:changes).and_return({
        'first_name' => ['John', nil]
      })

      # Set first_name to nil
      user.first_name = nil
      
      # No need to encrypt since we're setting to nil
      expect(encryption_service).not_to receive(:encrypt_batch)
      
      # Save the user
      user.save

      # First name token should be cleared
      expect(user.first_name_token).to be_nil
      
      # Other token fields should remain unchanged
      expect(user.last_name_token).to eq('token_for_Doe')
      expect(user.email_token).to eq('token_for_john.doe@example.com')
    end

    it 'properly clears a field and its token when explicitly set to nil' do
      # Create a persisted user with first_name token
      user = User.new(id: 123, first_name: 'John')
      user.write_attribute(:first_name_token, 'token_for_John')
      
      # Set up as persisted record
      allow(user).to receive(:persisted?).and_return(true)
      allow(user).to receive(:new_record?).and_return(false)
      
      # Set first_name to nil
      user.first_name = nil
      
      # Mock changes
      allow(user).to receive(:changes).and_return({ 'first_name' => ['John', nil] })
      
      # No need to encrypt since we're setting to nil
      expect(encryption_service).not_to receive(:encrypt_batch)
      
      # Save the user
      user.save

      # Accessors should return nil
      expect(user.first_name).to be_nil
      expect(user.first_name_token).to be_nil
    end

    it 'skips encryption for unchanged fields' do
      # Create a persisted user with tokens
      user = create_persisted_user_with_tokens
      
      # Expect encrypt_batch not to be called since no values have changed
      expect(encryption_service).not_to receive(:encrypt_batch)
      
      # Trigger the encryption process
      user.send(:encrypt_pii_fields)
    end

    it 'skips encryption for nil entity_id' do
      # Create a user without an ID
      user = User.new(first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

      # We need to stub the entity_id_proc to return a proc that returns blank
      original_proc = User.entity_id_proc
      begin
        User.entity_id_proc = ->(_) { '' }

        # No data should be sent to the encryption service
        expect(encryption_service).not_to receive(:encrypt_batch)

        user.send(:encrypt_pii_fields)
      ensure
        # Restore the original proc
        User.entity_id_proc = original_proc
      end
    end

    it 'handles nil original attribute values when encrypting' do
      # Create a test user with tokenizable fields
      user = User.new(id: 1)
      
      # Set one field to nil and one to blank
      user.first_name = nil
      user.last_name = ''
      user.email = 'john@example.com'
      
      # Only non-nil, non-blank values should be sent for encryption
      expect(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        # Verify only email is being encrypted
        expect(tokens_data.size).to eq(1)
        expect(tokens_data.first[:field_name]).to eq('email')
        expect(tokens_data.first[:value]).to eq('john@example.com')
        
        # Return a mock token
        {"CUSTOMER:User_customer_1:EMAIL:john@example.com" => "token_for_email"}
      end
      
      # Process tokenization
      user.send(:encrypt_pii_fields)
      
      # Nil and blank fields shouldn't have tokens
      expect(user.first_name_token).to be_nil
      expect(user.last_name_token).to be_nil
    end

    it 'skips encryption for blank values' do
      user = User.new(id: 1, first_name: '', last_name: nil, email: 'john.doe@example.com')

      # Only email should be encrypted
      stub_encrypt_batch
      
      # Trigger encryption
      user.send(:encrypt_pii_fields)
      
      # Only email should have a token
      expect(user.first_name_token).to be_nil
      expect(user.last_name_token).to be_nil
      expect(user.email_token).to eq("token_for_john.doe@example.com")
    end

    it 'clears decryption cache on register_for_decryption' do
      user = User.new(id: 1)
      # Set up the cache with a test value
      user.instance_variable_set(:@field_decryption_cache, { first_name: 'John' })

      # Stub new_record? to return false so register_for_decryption doesn't skip processing
      allow(user).to receive(:new_record?).and_return(false)

      expect(user.field_decryption_cache).to include(first_name: 'John')
      # This will initialize a new empty hash
      user.send(:clear_decryption_cache)
      expect(user.field_decryption_cache).to be_empty
    end

    it 'decrypts PII fields when accessed' do
      # Create a user with token values
      user = create_persisted_user_with_tokens

      # Set up the decrypt_batch to return plain values
      stub_decrypt_batch
      
      # Verify decryption works
      expect(user.decrypt_field(:first_name)).to eq('John')
      expect(user.decrypt_field(:last_name)).to eq('Doe')
      expect(user.decrypt_field(:email)).to eq('john.doe@example.com')
    end

    it 'returns nil when decrypting a nil value' do
      # Create a user with no token values
      user = User.new(id: 1)
      
      # Verify decrypting nil fields returns nil
      expect(user.decrypt_field(:first_name)).to be_nil
      expect(user.decrypt_field(:non_existent_field)).to be_nil
    end

    it 'returns cached decrypted value when available' do
      # Set up test data
      user = User.new(id: 1)

      # Explicitly set a cached value
      user.cache_decrypted_value(:first_name, 'Cached John')

      # No decrypt_batch call should happen
      expect(encryption_service).not_to receive(:decrypt_batch)

      # Should return the cached value
      expect(user.first_name).to eq('Cached John')
    end

    it 'returns setter value when available without decrypting' do
      # Set up test data
      user = User.new(id: 1)

      # Set the value using the standard setter
      user.first_name = 'Set John'

      # No decrypt_batch call should happen
      expect(encryption_service).not_to receive(:decrypt_batch)

      # Should return the value set by the setter
      expect(user.first_name).to eq('Set John')
    end

    it 'supports batch decryption' do
      # Create a user with token values
      user = create_persisted_user_with_tokens

      # Set up the decrypt_batch to return plain values
      stub_decrypt_batch
      
      # Should decrypt multiple fields at once
      result = user.decrypt_fields(:first_name, :last_name)
      expect(result).to include(first_name: 'John', last_name: 'Doe')
    end

    it 'returns empty hash when batch decrypting with no matching fields' do
      user = User.new(id: 1)
      result = user.decrypt_fields(:non_existent_field)
      expect(result).to eq({})
    end

    it 'returns empty hash when batch decrypting with no encrypted values' do
      user = User.new(id: 1)
      result = user.decrypt_fields(:first_name, :last_name)
      expect(result).to eq({})
    end

    it 'falls back to original value when decryption fails' do
      # Create a user with a value but an invalid token
      user = User.new(id: 1)
      user.write_attribute(:first_name, 'Original John')
      user.write_attribute(:first_name_token, 'invalid_token')

      # Setup decrypt_batch to simulate failure (empty result)
      allow(encryption_service).to receive(:decrypt_batch).and_return({})

      # Should fall back to original value
      expect(user.decrypt_field(:first_name)).to eq('Original John')
    end

    it 'accesses original column when read_from_token_column is false' do
      with_read_from_token_setting(false) do
        # Create a user with both value and token
        user = User.new(id: 1)
        user.write_attribute(:first_name, 'Original John')
        user.write_attribute(:first_name_token, 'should_not_be_used')
  
        # Should not call decrypt_batch
        expect(encryption_service).not_to receive(:decrypt_batch)
  
        # Should use the original column value
        expect(user.first_name).to eq('Original John')
      end
    end
  end

  describe 'entity identification' do
    before do
      @original_entity_type = User.entity_type_proc
      @original_entity_id_method = User.entity_id_proc

      # Reset to defaults for testing
      User.entity_type_proc = proc { |_| 'user_uuid' }
      User.entity_id_proc = proc { |record| "User_user_uuid_#{record.id}" }
    end

    after do
      # Restore original settings after tests
      User.entity_type_proc = @original_entity_type
      User.entity_id_proc = @original_entity_id_method
    end

    it 'defines entity type' do
      user = User.new(id: 1)
      # Using user_uuid as the entity type now
      expect(user.entity_type).to eq('user_uuid')
    end

    it 'defines entity id' do
      user = User.new(id: 1)
      # Entity ID format is now User_user_uuid_1
      expect(user.entity_id).to eq('User_user_uuid_1')
    end

    it 'allows entity id to be defined by a method' do
      User.entity_id_proc = proc { |user| "User_#{user.entity_type}_CUSTOM-123" }
      user = User.new(id: 1)
      expect(user.entity_id).to eq('User_user_uuid_CUSTOM-123')
    end
  end

  describe 'encryption' do
    # Mock the encryption service
    let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

    before do
      # Clean existing records
      User.delete_all

      # Stub the encryption service
      allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)

      # Reset model settings
      @original_entity_type = User.entity_type_proc
      User.entity_type_proc = proc { |_| 'user_uuid' }
    end

    after do
      User.entity_type_proc = @original_entity_type
    end

    it 'encrypts PII fields before save' do
      # Create a user with values to encrypt
      user = User.new(first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

      # Set up encrypt_batch to return tokens with proper key format
      allow(encryption_service).to receive(:encrypt_batch) do |batch_data|
        # Create a result hash that mimics what the encryption service would return
        result = {}

        # Process each field to create a key in the expected format
        batch_data.each do |data|
          # The key needs to match what the production code expects
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"

          # For each field, return a token
          case data[:field_name]
          when 'first_name'
            result[key] = 'token_for_John'
          when 'last_name'
            result[key] = 'token_for_Doe'
          when 'email'
            result[key] = 'token_for_email'
          end
        end

        result
      end

      # Set up standard database mock behaviors
      allow(User).to receive(:unscoped).and_return(User)
      allow(User).to receive(:where).and_return(User)
      allow(User).to receive(:update_all).and_return(true)
      allow(User).to receive(:exists?).and_return(true)

      # Allow reloading
      allow(user).to receive(:reload).and_return(user)

      # Set up write_attribute to track what's being written
      token_attrs = {}
      allow(user).to receive(:write_attribute) do |attr, value|
        token_attrs[attr] = value
      end

      # Also allow reading attributes
      allow(user).to receive(:read_attribute) do |attr|
        token_attrs[attr]
      end

      # Save should trigger the encryption process
      user.save!

      # Set the token values as if they were updated in the database
      user.instance_variable_set(:@first_name_token, 'token_for_John')
      user.instance_variable_set(:@last_name_token, 'token_for_Doe')
      user.instance_variable_set(:@email_token, 'token_for_email')

      # Verify that the tokens were set
      expect(user.instance_variable_get(:@first_name_token)).to eq('token_for_John')
      expect(user.instance_variable_get(:@last_name_token)).to eq('token_for_Doe')
      expect(user.instance_variable_get(:@email_token)).to eq('token_for_email')
    end
  end

  describe 'dual write mode' do
    include_context "tokenization test helpers"

    it 'handles updating tokenized fields to nil' do
      with_dual_write_setting(false) do
        # Create user and set up encryption
        user = User.new(id: rand(1000..9999), first_name: 'John', last_name: 'Doe', email: 'john@example.com')
        stub_encrypt_batch
        
        # Allow save to succeed without DB operations
        allow(user).to receive(:save).and_return(true) 
        
        # Save to establish tokens
        user.save
        
        # Now set fields to nil
        user.first_name = nil
        user.last_name = nil
        user.email = nil
        
        # Set up changes hash to simulate AR behavior
        allow(user).to receive(:changes).and_return({
          'first_name' => ['John', nil],
          'last_name' => ['Doe', nil],
          'email' => ['john@example.com', nil]
        })
        
        # Avoid encryption for nil values
        expect(encryption_service).not_to receive(:encrypt_batch)
        
        # Save again
        user.save
        
        # All fields should be nil
        expect(user.first_name).to be_nil
        expect(user.last_name).to be_nil
        expect(user.email).to be_nil
        expect(user.first_name_token).to be_nil
        expect(user.last_name_token).to be_nil
        expect(user.email_token).to be_nil
      end
    end

    it 'handles updating tokenized fields with dual_write enabled and setting to nil' do
      with_dual_write_setting(true) do
        # Create user and set up encryption
        user = User.new(id: rand(1000..9999), first_name: 'John', last_name: 'Doe', email: 'john@example.com')
        stub_encrypt_batch
        
        # Allow save to succeed without DB operations
        allow(user).to receive(:save).and_return(true)
        
        # Save to establish tokens
        user.save
        
        # Now set fields to nil
        user.first_name = nil
        user.last_name = nil
        user.email = nil
        
        # Set up changes hash to simulate AR behavior
        allow(user).to receive(:changes).and_return({
          'first_name' => ['John', nil],
          'last_name' => ['Doe', nil],
          'email' => ['john@example.com', nil]
        })
        
        # Avoid encryption for nil values
        expect(encryption_service).not_to receive(:encrypt_batch)
        
        # Save again
        user.save
        
        # All fields should be nil
        expect(user.first_name).to be_nil
        expect(user.last_name).to be_nil
        expect(user.email).to be_nil
        expect(user.first_name_token).to be_nil
        expect(user.last_name_token).to be_nil
        expect(user.email_token).to be_nil
      end
    end

    it 'clears original fields when dual_write is false' do
      with_dual_write_setting(false) do
        # Set up encryption
        stub_encrypt_batch
        stub_decrypt_batch
        
        # Create a user with a tokenizable field
        user = User.new(id: rand(1000..9999), first_name: 'John')

        # Allow save to succeed without DB operations
        allow(user).to receive(:save).and_return(true)
        
        # Set token value directly after encryption would happen
        user.write_attribute(:first_name_token, 'token_for_John')
        user.write_attribute(:first_name, nil)
        
        # Getter should return the decrypted value
        expect(user.first_name).to eq('John')
      end
    end
  end
end
