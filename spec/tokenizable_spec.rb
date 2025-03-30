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

    it 'defines default pii_types for fields' do
      expect(User.pii_types).to include(
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      )
    end

    it 'defines entity type' do
      expect(user.entity_type).to eq('customer')
    end

    it 'defines entity id' do
      expect(user.entity_id).to eq('User_customer_1')
    end

    it 'encrypts PII fields before save' do
      encrypt_response = {
        'customer:User_customer_1:FIRST_NAME' => 'encrypted_first_name',
        'customer:User_customer_1:LAST_NAME' => 'encrypted_last_name',
        'customer:User_customer_1:EMAIL' => 'encrypted_email'
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

      user.save

      # The database values should be encrypted
      expect(user.read_attribute(:first_name)).to eq('encrypted_first_name')
      expect(user.read_attribute(:last_name)).to eq('encrypted_last_name')
      expect(user.read_attribute(:email)).to eq('encrypted_email')
    end

    it 'decrypts PII fields when accessed' do
      # Setup encrypted values in the database
      user.write_attribute(:first_name, 'encrypted_first_name')
      user.write_attribute(:last_name, 'encrypted_last_name')
      user.write_attribute(:email, 'encrypted_email')

      # Register for decryption
      user.register_for_decryption

      # Mock decryption response for a single field
      expect(encryption_service).to receive(:decrypt_batch).with(
        [
          {
            token: 'encrypted_first_name',
            entity_id: 'User_customer_1',
            entity_type: 'customer',
            field_name: 'first_name',
            pii_type: 'FIRST_NAME'
          }
        ]
      ).and_return({ 'customer:User_customer_1:FIRST_NAME' => 'John' })

      # The getter should return the decrypted value
      expect(user.first_name).to eq('John')
    end

    it 'supports batch decryption' do
      # Setup encrypted values in the database
      user.write_attribute(:first_name, 'encrypted_first_name')
      user.write_attribute(:last_name, 'encrypted_last_name')

      # Register for decryption
      user.register_for_decryption

      # Mock batch decryption response
      expect(encryption_service).to receive(:decrypt_batch).with(
        array_including(
          {
            token: 'encrypted_first_name',
            entity_id: 'User_customer_1',
            entity_type: 'customer',
            field_name: 'first_name',
            pii_type: 'FIRST_NAME'
          },
          {
            token: 'encrypted_last_name',
            entity_id: 'User_customer_1',
            entity_type: 'customer',
            field_name: 'last_name',
            pii_type: 'LAST_NAME'
          }
        )
      ).and_return({
                     'customer:User_customer_1:FIRST_NAME' => 'John',
                     'customer:User_customer_1:LAST_NAME' => 'Doe'
                   })

      # Should decrypt multiple fields in one call
      result = user.decrypt_fields(:first_name, :last_name)
      expect(result).to eq({ first_name: 'John', last_name: 'Doe' })
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
      expect(Contact.pii_types).to eq({
                                        full_name: 'NAME',
                                        phone_number: 'PHONE',
                                        email_address: 'EMAIL'
                                      })
    end

    it 'uses custom pii_types for encryption and decryption' do
      # Test the pii_type_for method
      expect(contact.pii_type_for(:full_name)).to eq('NAME')
      expect(contact.pii_type_for(:phone_number)).to eq('PHONE')
      expect(contact.pii_type_for(:email_address)).to eq('EMAIL')
    end
  end
end
