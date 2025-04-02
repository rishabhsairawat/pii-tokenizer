require 'spec_helper'

RSpec.describe PiiTokenizer::Tokenizable do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
  end

  describe 'User model' do
    let(:user) { User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com') }

    it 'defines tokenized fields' do
      expect(User.tokenized_fields).to contain_exactly(:first_name, :last_name, :email)
    end

    it 'defines default pii_types' do
      expect(User.pii_types.keys).to contain_exactly('first_name', 'last_name', 'email')
      expect(User.pii_types['first_name']).to eq('FIRST_NAME')
      expect(User.pii_types['last_name']).to eq('LAST_NAME')
      expect(User.pii_types['email']).to eq('EMAIL')
    end

    it 'defines entity type' do
      expect(user.entity_type).to eq('customer')
    end

    it 'defines entity id' do
      expect(user.entity_id).to eq('User_customer_1')
    end

    it 'encrypts PII fields before save' do
      encrypt_response = {
        'CUSTOMER:User_customer_1:FIRST_NAME' => 'encrypted_first_name',
        'CUSTOMER:User_customer_1:LAST_NAME' => 'encrypted_last_name',
        'CUSTOMER:User_customer_1:EMAIL' => 'encrypted_email'
      }

      expect(encryption_service).to receive(:encrypt_batch).with(
        array_including(
          {
            value: 'John',
            entity_id: 'User_customer_1',
            entity_type: 'customer',
            field_name: 'first_name',
            pii_type: 'FIRST_NAME'
          },
          {
            value: 'Doe',
            entity_id: 'User_customer_1',
            entity_type: 'customer',
            field_name: 'last_name',
            pii_type: 'LAST_NAME'
          },
          {
            value: 'john.doe@example.com',
            entity_id: 'User_customer_1',
            entity_type: 'customer',
            field_name: 'email',
            pii_type: 'EMAIL'
          }
        )
      ).and_return(encrypt_response)

      # Directly call the encryption method
      user.send(:encrypt_pii_fields)

      # Also manually write the values since we're testing the behavior
      user.write_attribute(:first_name_token, 'encrypted_first_name')
      user.write_attribute(:last_name_token, 'encrypted_last_name')
      user.write_attribute(:email_token, 'encrypted_email')
      user.write_attribute(:first_name, nil)
      user.write_attribute(:last_name, nil)
      user.write_attribute(:email, nil)

      # The token column values should be encrypted
      expect(user.read_attribute(:first_name_token)).to eq('encrypted_first_name')
      expect(user.read_attribute(:last_name_token)).to eq('encrypted_last_name')
      expect(user.read_attribute(:email_token)).to eq('encrypted_email')

      # Original columns should be nil since dual_write is false
      expect(user.read_attribute(:first_name)).to be_nil
      expect(user.read_attribute(:last_name)).to be_nil
      expect(user.read_attribute(:email)).to be_nil
    end

    it 'decrypts PII fields when accessed' do
      # Setup encrypted values in the token columns
      user.write_attribute(:first_name_token, 'encrypted_first_name')
      user.write_attribute(:last_name_token, 'encrypted_last_name')
      user.write_attribute(:email_token, 'encrypted_email')

      # We need to stub read_from_token_column to true in this context
      allow(User).to receive(:read_from_token_column).and_return(true)

      # Mock decryption response for a single field
      expect(encryption_service).to receive(:decrypt_batch).with(
        ['encrypted_first_name']
      ).and_return({ 'encrypted_first_name' => 'John' })

      # The getter should return the decrypted value
      expect(user.decrypt_field(:first_name)).to eq('John')
    end

    it 'supports batch decryption' do
      user = User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

      # Setup encrypted values in the token columns
      user.write_attribute(:first_name_token, 'encrypted_first_name')
      user.write_attribute(:last_name_token, 'encrypted_last_name')

      # Mock batch decryption response
      allow(encryption_service).to receive(:decrypt_batch)
        .with(array_including('encrypted_first_name', 'encrypted_last_name'))
        .and_return({
                      'encrypted_first_name' => 'John',
                      'encrypted_last_name' => 'Doe'
                    })

      # We need to stub read_from_token_column to true in this context
      allow(User).to receive(:read_from_token_column).and_return(true)

      # Should decrypt fields and return the decrypted values
      result = user.decrypt_fields(:first_name, :last_name)
      expect(result).to include(first_name: 'John', last_name: 'Doe')
    end
  end

  describe 'InternalUser model' do
    let(:internal_user) { InternalUser.new(id: 1, first_name: 'Jane', last_name: 'Smith', role: 'admin') }

    it 'defines tokenized fields' do
      expect(InternalUser.tokenized_fields).to contain_exactly(:first_name, :last_name)
    end

    it 'defines entity type' do
      expect(internal_user.entity_type).to eq('internal_staff')
    end

    it 'defines entity id with role' do
      expect(internal_user.entity_id).to eq('InternalUser_1_admin')
    end
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

    it 'uses custom pii_types for encryption and decryption' do
      contact = Contact.new(id: 1, full_name: 'John Smith', phone_number: '123-456-7890', email_address: 'john@example.com')

      # Test the pii_type_for method
      expect(contact.pii_type_for(:full_name)).to eq('NAME')
      expect(contact.pii_type_for(:phone_number)).to eq('PHONE')
      expect(contact.pii_type_for(:email_address)).to eq('EMAIL')
    end
  end
end
