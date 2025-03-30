require 'spec_helper'

RSpec.describe 'Custom PII Types' do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
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

    it 'uses the custom pii_types when encrypting' do
      encrypt_response = {
        'contact:Contact_1:NAME' => 'encrypted_name_token',
        'contact:Contact_1:PHONE' => 'encrypted_phone_token',
        'contact:Contact_1:EMAIL' => 'encrypted_email_token'
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

      contact.save

      # The database values should be encrypted
      expect(contact.read_attribute(:full_name)).to eq('encrypted_name_token')
      expect(contact.read_attribute(:phone_number)).to eq('encrypted_phone_token')
      expect(contact.read_attribute(:email_address)).to eq('encrypted_email_token')
    end

    it 'uses the custom pii_types when decrypting' do
      # Setup encrypted values in the database
      contact.write_attribute(:full_name, 'encrypted_name_token')
      contact.write_attribute(:phone_number, 'encrypted_phone_token')

      # Register for decryption
      contact.register_for_decryption

      # Mock batch decryption response
      expect(encryption_service).to receive(:decrypt_batch).with(
        array_including(
          {
            token: 'encrypted_name_token',
            entity_id: 'Contact_1',
            entity_type: 'contact',
            field_name: 'full_name',
            pii_type: 'NAME'
          },
          {
            token: 'encrypted_phone_token',
            entity_id: 'Contact_1',
            entity_type: 'contact',
            field_name: 'phone_number',
            pii_type: 'PHONE'
          }
        )
      ).and_return({
                     'contact:Contact_1:NAME' => 'John Smith',
                     'contact:Contact_1:PHONE' => '123-456-7890'
                   })

      # Should decrypt multiple fields in one call
      result = contact.decrypt_fields(:full_name, :phone_number)
      expect(result).to eq({ full_name: 'John Smith', phone_number: '123-456-7890' })
    end
  end
end
