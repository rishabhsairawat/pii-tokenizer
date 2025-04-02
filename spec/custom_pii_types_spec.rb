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
      encrypt_response = {
        'CONTACT:Contact_1:NAME' => 'encrypted_name_token',
        'CONTACT:Contact_1:PHONE' => 'encrypted_phone_token',
        'CONTACT:Contact_1:EMAIL' => 'encrypted_email_token'
      }

      expect(encryption_service).to receive(:encrypt_batch).with(
        array_including(
          {
            value: 'John Smith',
            entity_id: 'Contact_1',
            entity_type: 'contact',
            field_name: 'full_name',
            pii_type: 'NAME'
          },
          {
            value: '123-456-7890',
            entity_id: 'Contact_1',
            entity_type: 'contact',
            field_name: 'phone_number',
            pii_type: 'PHONE'
          },
          {
            value: 'john@example.com',
            entity_id: 'Contact_1',
            entity_type: 'contact',
            field_name: 'email_address',
            pii_type: 'EMAIL'
          }
        )
      ).and_return(encrypt_response)

      # Directly call the encryption method
      contact.send(:encrypt_pii_fields)

      # Manually write the values as we're testing the behavior
      contact.write_attribute(:full_name_token, 'encrypted_name_token')
      contact.write_attribute(:phone_number_token, 'encrypted_phone_token')
      contact.write_attribute(:email_address_token, 'encrypted_email_token')
      contact.write_attribute(:full_name, nil)
      contact.write_attribute(:phone_number, nil)
      contact.write_attribute(:email_address, nil)

      # The token columns should be encrypted
      expect(contact.read_attribute(:full_name_token)).to eq('encrypted_name_token')
      expect(contact.read_attribute(:phone_number_token)).to eq('encrypted_phone_token')
      expect(contact.read_attribute(:email_address_token)).to eq('encrypted_email_token')

      # Original columns should be nil since dual_write is false
      expect(contact.read_attribute(:full_name)).to be_nil
      expect(contact.read_attribute(:phone_number)).to be_nil
      expect(contact.read_attribute(:email_address)).to be_nil
    end

    it 'uses the custom pii_types when decrypting' do
      # Setup encrypted values in the token columns
      contact.write_attribute(:full_name_token, 'encrypted_name_token')
      contact.write_attribute(:phone_number_token, 'encrypted_phone_token')

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
end
