require 'spec_helper'

RSpec.describe 'Custom PII Types' do
  before do
    # Configure the encryption service mock
    # Remove: rely on global mock setup in spec_helper
    # allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)

    # Explicitly allow update_all if needed by the test, but prefer letting AR run
    # Allow update_all for the after_save callback - REMOVE this mock
    # allow(Contact).to receive_message_chain(:unscoped, :where, :update_all)
  end

  describe 'Contact model with custom pii_types' do
    let(:contact) { Contact.new(id: 1, full_name: 'Test Contact', phone_number: '123-456-7890') }

    # before do
      # Remove redundant encrypt_batch mock - rely on global mock
      # allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
      #   result = {}
      #   tokens_data.each do |data|
      #     key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:field_name]}"
      #     result[key] = "token_for_#{data[:value]}_as_#{data[:pii_type]}"
      #   end
      #   result
      # end
    # end

    it 'uses the custom pii_types when encrypting' do
      # Trigger the callbacks by saving
      contact.save! # Let AR handle save and callbacks

      # Check if the global mock service was called with the correct PII types
      expect(PiiTokenizer.encryption_service).to have_received(:encrypt_batch).with(
        a_collection_containing_exactly(
          hash_including(pii_type: 'NAME', value: 'Test Contact'),
          hash_including(pii_type: 'PHONE', value: '123-456-7890')
        )
      ).at_least(:once)

      # Check the resulting token (set by after_save using global mock)
      # Tokens will now follow the global mock pattern
      expect(contact.full_name_token).to match(/^mock_token_\d+_for_\[Test Contact\]_as_\[NAME\]$/)
      expect(contact.phone_number_token).to match(/^mock_token_\d+_for_\[123-456-7890\]_as_\[PHONE\]$/)
    end

    it 'uses the custom pii_types when decrypting' do
      # Setup encrypted values in the token columns using the mock pattern
      contact.write_attribute(:full_name_token, 'mock_token_0_for_[John Smith]_as_[NAME]')
      contact.write_attribute(:phone_number_token, 'mock_token_1_for_[123-456-7890]_as_[PHONE]')

      # No need to mock read_from_token_column, done in global before(:each)
      # No need to mock decrypt_batch, done in global before(:each)

      # Should decrypt multiple fields in one call
      result = contact.decrypt_fields(:full_name, :phone_number)
      expect(PiiTokenizer.encryption_service).to have_received(:decrypt_batch).with(
        array_including('mock_token_0_for_[John Smith]_as_[NAME]', 'mock_token_1_for_[123-456-7890]_as_[PHONE]')
      ).at_least(:once)
      expect(result).to include(full_name: 'John Smith', phone_number: '123-456-7890')
    end
  end

  describe 'Standard query methods with tokenized fields' do
    # before do
      # Global mock handles read_from_token_column setup
      # Global mock handles encryption service setup for create!

      # Spy on search_tokens (remove and_call_original)
      # Let the global mock handle search_tokens by default
      # Specific tests can override if needed
      # allow(PiiTokenizer.encryption_service).to receive(:search_tokens)
    # end

    it 'uses tokenized search in find_by' do
      # Create user for this test - this will use the global mock for encryption
      user = User.create!(id: 1, first_name: 'John')

      # Verify User model setup (still useful)
      expect(User.tokenized_fields).to include(:first_name)
      # Global mock ensures read_from_token_column is true by default

      # Mock search_tokens to return the specific token format our global encrypt mock creates
      # The global search mock is basic; we need a more specific one here.
      expected_token = user.first_name_token # Get the token actually stored by the global mock
      allow(PiiTokenizer.encryption_service).to receive(:search_tokens)
        .with('John')
        .and_return([expected_token]) # Return the *actual* mock token

      # Call find_by
      result = User.find_by(first_name: 'John')

      # Assertions
      expect(PiiTokenizer.encryption_service).to have_received(:search_tokens).with('John').at_least(:once)
      expect(result).to eq(user)
    end

    it 'uses tokenized search with search_all_by_tokenized_field' do
       # Create user for this test
       user = User.create!(id: 1, first_name: 'John')

       # Mock search_tokens - needs to return the actual token stored
       expected_token = user.first_name_token
       allow(PiiTokenizer.encryption_service).to receive(:search_tokens)
         .with('John')
         .and_return([expected_token])

       results = User.search_all_by_tokenized_field(:first_name, 'John')

       expect(PiiTokenizer.encryption_service).to have_received(:search_tokens).with('John').at_least(:once)
       expect(results).to contain_exactly(user)
    end

    it 'handles mixed tokenized and non-tokenized fields in find_by' do
      # Create user for this test
      user = User.create!(id: 1, first_name: 'John')

      # Verify User model setup
      expect(User.tokenized_fields).to include(:first_name)
      # Global mock sets read_from_token_column

      # Mock search_tokens for the tokenized field
      expected_token = user.first_name_token
      allow(PiiTokenizer.encryption_service).to receive(:search_tokens)
        .with('John')
        .and_return([expected_token])

      # Find by mix of ID (non-tokenized) and first_name (tokenized)
      result = User.find_by(id: user.id, first_name: 'John')

      expect(PiiTokenizer.encryption_service).to have_received(:search_tokens).with('John').at_least(:once)
      expect(result).to eq(user)
    end
  end
end
