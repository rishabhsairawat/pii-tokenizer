require 'spec_helper'

RSpec.describe PiiTokenizer::Tokenizable do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
  end

  describe 'attribute writers' do
    it 'sets instance variable and original value with attribute writer' do
      user = User.new(id: 1)
      user.first_name = 'John'

      expect(user.instance_variable_get('@original_first_name')).to eq('John')
      expect(user.first_name).to eq('John')
    end

    it 'preserves case for values in writer' do
      user = User.new(id: 1)
      user.first_name = 'John Doe'

      expect(user.instance_variable_get('@original_first_name')).to eq('John Doe')
      expect(user.first_name).to eq('John Doe')
    end

    it 'handles nil values in writer' do
      user = User.new(id: 1)
      user.first_name = nil

      expect(user.instance_variable_get('@original_first_name')).to be_nil
      expect(user.first_name).to be_nil
    end

    it 'handles non-string values in writer' do
      user = User.new(id: 1)
      user.first_name = 123

      # The implementation keeps the original type for numeric values
      expect(user.instance_variable_get('@original_first_name')).to eq(123)
      expect(user.first_name).to eq(123)
    end
  end

  describe 'batch operations' do
    before do
      User.delete_all
    end

    it 'supports batch decryption with include_decrypted_fields' do
      # Create several users with token values
      users = Array.new(3) { |i| User.new(id: i + 1) }
      users.each_with_index do |user, i|
        user.safe_write_attribute(:first_name_token, "encrypted_first_name_#{i}")
        user.safe_write_attribute(:last_name_token, "encrypted_last_name_#{i}")
        # Simulate save without actually saving to DB
        allow(user).to receive(:persisted?).and_return(true)
        allow(user).to receive(:new_record?).and_return(false)
      end

      # Setup relation with decrypted fields (use a mock to avoid actual DB queries)
      relation = double('ActiveRecord::Relation')
      allow(relation).to receive(:to_a).and_return(users)

      # Add the Tokenizable extension
      relation.extend(PiiTokenizer::Tokenizable::DecryptedFieldsExtension)

      # Set up expected batch decryption
      tokens = users.map(&:first_name_token)
      decryption_result = tokens.each_with_object({}) do |token, result|
        result[token] = token.sub('encrypted_', '')
      end

      # Allow the batch decryption method to be called
      allow(encryption_service).to receive(:decrypt_batch)
        .with(array_including(*tokens))
        .and_return(decryption_result)

      # Allow User class to use our preload method
      allow(User).to receive(:preload_decrypted_fields).and_call_original

      # Call to_a on the relation, should trigger preloading
      relation.decrypt_fields([:first_name])
      result = relation.to_a

      # Check that the decryption result matches
      expect(result).to eq(users)
    end

    it "supports User class's preload_decrypted_fields method" do
      # Create two test users
      user1 = User.new(id: 1)
      user1.safe_write_attribute(:first_name_token, 'encrypted_first_name_1')
      user1.safe_write_attribute(:last_name_token, 'encrypted_last_name_1')

      user2 = User.new(id: 2)
      user2.safe_write_attribute(:first_name_token, 'encrypted_first_name_2')
      user2.safe_write_attribute(:last_name_token, 'encrypted_last_name_2')

      users = [user1, user2]

      # Setup decryption response
      decrypt_response = {
        'encrypted_first_name_1' => 'John',
        'encrypted_first_name_2' => 'Jane',
        'encrypted_last_name_1' => 'Doe',
        'encrypted_last_name_2' => 'Smith'
      }

      # Set expectations for the encryption service
      expect(encryption_service).to receive(:decrypt_batch)
        .with(array_including('encrypted_first_name_1', 'encrypted_first_name_2'))
        .and_return(decrypt_response)

      # Allow reading from token column
      allow(User).to receive(:read_from_token_column).and_return(true)

      # Test the preload_decrypted_fields method
      User.preload_decrypted_fields(users, :first_name)

      # Check that the values are preloaded in the cache
      expect(user1.first_name).to eq('John')
      expect(user2.first_name).to eq('Jane')
    end
  end

  describe 'field readers' do
    it 'returns value from field_decryption_cache if available' do
      user = User.new(id: 1)
      user.instance_variable_set(:@field_decryption_cache, { first_name: 'Cached John' })

      expect(user.first_name).to eq('Cached John')
    end

    it 'falls back to original column when not found in token column' do
      user = User.new(id: 1)
      user.safe_write_attribute(:first_name, 'Original John')
      user.safe_write_attribute(:first_name_token, nil)

      # Allow reading from token column
      allow(User).to receive(:read_from_token_column).and_return(true)

      # Mock the decryption to return an empty hash (not found)
      allow(encryption_service).to receive(:decrypt_batch).and_return({})

      expect(user.first_name).to eq('Original John')
    end
  end
end
