require 'spec_helper'

RSpec.describe 'Custom PII Types' do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    # Configure the encryption service mock
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
  end

  describe 'Contact model with custom pii_types' do
    let(:contact) { Contact.new(id: 1, full_name: 'John Smith', phone_number: '123-456-7890', email_address: 'john@example.com') }

    it 'defines tokenized fields with custom pii_types' do
      expect(Contact.tokenized_fields).to contain_exactly(:full_name, :phone_number, :email_address)
      expect(Contact.pii_types.keys).to contain_exactly('full_name', 'phone_number', 'email_address')
      expect(Contact.pii_types['full_name']).to eq('NAME')
      expect(Contact.pii_types['phone_number']).to eq('PHONE')
      expect(Contact.pii_types['email_address']).to eq('EMAIL')
    end

    it 'uses the custom pii_types when encrypting' do
      # Set up test data
      contact = Contact.new(id: 1, full_name: 'John Smith', phone_number: '123-456-7890', email_address: 'john@example.com')

      # Allow persisted? and entity_id to work
      allow(contact).to receive(:persisted?).and_return(true)
      allow(contact).to receive(:new_record?).and_return(false)

      # Set up the encryption service expectation
      expect(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        # Verify the tokens_data contains the correct pii_types
        expect(tokens_data).to include(
          hash_including(
            entity_type: PiiTokenizer::EntityTypes::USER_UUID,
            entity_id: 'Contact_1',
            field_name: 'full_name',
            pii_type: 'NAME',
            value: 'John Smith'
          ),
          hash_including(
            entity_type: PiiTokenizer::EntityTypes::USER_UUID,
            entity_id: 'Contact_1',
            field_name: 'phone_number',
            pii_type: 'PHONE',
            value: '123-456-7890'
          ),
          hash_including(
            entity_type: PiiTokenizer::EntityTypes::USER_UUID,
            entity_id: 'Contact_1',
            field_name: 'email_address',
            pii_type: 'EMAIL',
            value: 'john@example.com'
          )
        )

        # Return mock tokens
        {
          'USER_UUID:Contact_1:NAME:John Smith' => 'encrypted_name_token',
          'USER_UUID:Contact_1:PHONE:123-456-7890' => 'encrypted_phone_token',
          'USER_UUID:Contact_1:EMAIL:john@example.com' => 'encrypted_email_token'
        }
      end

      # Create a mock for update_all to prevent actual DB operations
      db_updates = {}
      allow(Contact).to receive(:unscoped).and_return(Contact)
      allow(Contact).to receive(:where).and_return(Contact)
      allow(Contact).to receive(:update_all) do |updates|
        db_updates = updates
        1 # Return 1 row affected
      end

      # Trigger the encryption
      contact.send(:encrypt_pii_fields)

      # Verify that correct token values would be stored
      expect(contact.full_name_token).to eq('encrypted_name_token')
      expect(contact.phone_number_token).to eq('encrypted_phone_token')
      expect(contact.email_address_token).to eq('encrypted_email_token')
    end

    it 'uses the custom pii_types when decrypting' do
      # Set up test data
      contact = Contact.new(id: 42)

      # Manually set token values
      contact.safe_write_attribute(:full_name_token, 'encrypted_name_token')
      contact.safe_write_attribute(:phone_number_token, 'encrypted_phone_token')

      allow(contact).to receive(:persisted?).and_return(true)

      # We need to stub read_from_token_column to true in this context
      allow(Contact).to receive(:read_from_token_column).and_return(true)

      # Mock batch decryption response
      allow(encryption_service).to receive(:decrypt_batch)
        .with(array_including('encrypted_name_token', 'encrypted_phone_token'))
        .and_return({
                      'encrypted_name_token' => 'John Smith',
                      'encrypted_phone_token' => '123-456-7890'
                    })

      # Should decrypt multiple fields in one call
      result = contact.decrypt_fields(:full_name, :phone_number)
      expect(result).to include(full_name: 'John Smith', phone_number: '123-456-7890')
    end
  end

  describe 'Standard query methods with tokenized fields' do
    # Use a more integrated approach for these tests
    before do
      # Configure the model to explicitly use tokenization - we need this to be handled first
      class_double = class_double('Contact', read_from_token_column: true)
      allow(Contact).to receive(:read_from_token_column).and_return(true)

      # Setup the search_tokens mock WITHOUT expectations
      allow(encryption_service).to receive(:search_tokens).and_return(['encrypted_email_token'])

      # Only stub what's necessary to prevent actual database operations
      allow(Contact).to receive(:none).and_return([])
      allow(Contact).to receive(:find_by).and_call_original # Let original method execute
      allow(Contact).to receive(:where).and_call_original # Let original method execute

      # Just prevent database queries from running
      empty_relation = double('EmptyRelation')
      allow(empty_relation).to receive(:where).and_return(empty_relation)
      allow(empty_relation).to receive(:first).and_return(nil)
      allow(ActiveRecord::Base).to receive(:where).and_return(empty_relation)
    end

    it 'uses tokenized search in find_by' do
      # Reset counter and track if search_tokens is called
      @search_tokens_called = false
      allow(encryption_service).to receive(:search_tokens) do |_arg|
        @search_tokens_called = true
        ['encrypted_email_token']
      end

      # Call the method
      Contact.find_by(email_address: 'john@example.com')

      # Verify search_tokens was called
      expect(@search_tokens_called).to be true
    end

    it 'uses tokenized search in where' do
      # Reset counter and track if search_tokens is called
      @search_tokens_called = false
      allow(encryption_service).to receive(:search_tokens) do |_arg|
        @search_tokens_called = true
        ['encrypted_email_token']
      end

      # Call the method
      Contact.where(email_address: 'john@example.com')

      # Verify search_tokens was called
      expect(@search_tokens_called).to be true
    end

    it 'handles mixed tokenized and non-tokenized fields' do
      # Reset counter and track if search_tokens is called
      @search_tokens_called = false
      allow(encryption_service).to receive(:search_tokens) do |_arg|
        @search_tokens_called = true
        ['encrypted_email_token']
      end

      # Call the method
      Contact.where(id: 1, email_address: 'john@example.com')

      # Verify search_tokens was called
      expect(@search_tokens_called).to be true
    end
  end
end
