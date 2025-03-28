require "spec_helper"

RSpec.describe PiiTokenizer::Tokenizable do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }
  
  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
  end

  describe "User model" do
    let(:user) { User.new(id: 1, first_name: "John", last_name: "Doe", email: "john.doe@example.com") }

    it "defines tokenized fields" do
      expect(User.tokenized_fields).to contain_exactly(:first_name, :last_name, :email)
    end

    it "defines entity type" do
      expect(user.entity_type).to eq("customer")
    end

    it "defines entity id" do
      expect(user.entity_id).to eq("User_customer_1")
    end

    it "encrypts PII fields before save" do
      encrypt_response = {
        "customer:User_customer_1:first_name" => "encrypted_first_name",
        "customer:User_customer_1:last_name" => "encrypted_last_name",
        "customer:User_customer_1:email" => "encrypted_email"
      }

      expect(encryption_service).to receive(:encrypt_batch).with(
        array_including(
          {
            value: "John",
            entity_id: "User_customer_1",
            entity_type: "customer",
            field_name: "first_name"
          },
          {
            value: "Doe",
            entity_id: "User_customer_1",
            entity_type: "customer",
            field_name: "last_name"
          },
          {
            value: "john.doe@example.com",
            entity_id: "User_customer_1",
            entity_type: "customer",
            field_name: "email"
          }
        )
      ).and_return(encrypt_response)

      user.save
      
      # The database values should be encrypted
      expect(user.read_attribute(:first_name)).to eq("encrypted_first_name")
      expect(user.read_attribute(:last_name)).to eq("encrypted_last_name")
      expect(user.read_attribute(:email)).to eq("encrypted_email")
    end

    it "decrypts PII fields when accessed" do
      # Setup encrypted values in the database
      user.write_attribute(:first_name, "encrypted_first_name")
      user.write_attribute(:last_name, "encrypted_last_name")
      user.write_attribute(:email, "encrypted_email")
      
      # Register for decryption
      user.register_for_decryption
      
      # Mock decryption response for a single field
      expect(encryption_service).to receive(:decrypt_batch).with(
        [
          {
            token: "encrypted_first_name",
            entity_id: "User_customer_1",
            entity_type: "customer",
            field_name: "first_name"
          }
        ]
      ).and_return({"customer:User_customer_1:first_name" => "John"})
      
      # The getter should return the decrypted value
      expect(user.first_name).to eq("John")
    end

    it "supports batch decryption" do
      # Setup encrypted values in the database
      user.write_attribute(:first_name, "encrypted_first_name")
      user.write_attribute(:last_name, "encrypted_last_name")
      
      # Register for decryption
      user.register_for_decryption
      
      # Mock batch decryption response
      expect(encryption_service).to receive(:decrypt_batch).with(
        array_including(
          {
            token: "encrypted_first_name",
            entity_id: "User_customer_1",
            entity_type: "customer",
            field_name: "first_name"
          },
          {
            token: "encrypted_last_name",
            entity_id: "User_customer_1",
            entity_type: "customer",
            field_name: "last_name"
          }
        )
      ).and_return({
        "customer:User_customer_1:first_name" => "John",
        "customer:User_customer_1:last_name" => "Doe"
      })
      
      # Should decrypt multiple fields in one call
      result = user.decrypt_fields(:first_name, :last_name)
      expect(result).to eq({first_name: "John", last_name: "Doe"})
    end
  end

  describe "InternalUser model" do
    let(:internal_user) { InternalUser.new(id: 1, first_name: "Jane", last_name: "Smith", role: "admin") }

    it "defines tokenized fields" do
      expect(InternalUser.tokenized_fields).to contain_exactly(:first_name, :last_name)
    end

    it "defines entity type" do
      expect(internal_user.entity_type).to eq("internal_staff")
    end

    it "defines entity id with role" do
      expect(internal_user.entity_id).to eq("InternalUser_1_admin")
    end
  end
end 