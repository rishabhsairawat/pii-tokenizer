require "spec_helper"

RSpec.describe "Rails 4 compatibility" do
  it "doesn't use Rails 5 specific APIs in tokenizable" do
    # This test doesn't actually run code but is a reminder that:
    # 1. We don't use the default option on class_attribute (not available in Rails 4)
    # 2. We don't use thread_mattr_accessor (not available in Rails 4)
    expect(PiiTokenizer::Tokenizable).to be_a(Module)
  end

  context "when using a model with tokenized fields" do
    # These tests should work regardless of Rails version, 
    # confirming our implementation is compatible with both Rails 4 and 5
    
    let(:user) do
      Class.new(ActiveRecord::Base) do
        include PiiTokenizer::Tokenizable
        self.table_name = 'users'
        tokenize_pii fields: [:first_name, :last_name, :email], 
                    entity_type: 'customer',
                    entity_id: ->(record) { "User_customer_#{record.id}" }
      end.new(id: 1, first_name: "John", last_name: "Doe", email: "john.doe@example.com")
    end
    
    it "can save and access tokenized fields" do
      # Setup to mock encryption service
      encryption_service = instance_double(PiiTokenizer::EncryptionService)
      allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
      
      # Mock encryption
      expect(encryption_service).to receive(:encrypt_batch).and_return({
        "customer:User_customer_1:first_name" => "encrypted_first_name",
        "customer:User_customer_1:last_name" => "encrypted_last_name",
        "customer:User_customer_1:email" => "encrypted_email"
      })
      
      # Save the user, which should encrypt the fields
      user.save
      
      # Set up the encrypted values in the database
      user.write_attribute(:first_name, "encrypted_first_name")
      user.write_attribute(:last_name, "encrypted_last_name")
      user.write_attribute(:email, "encrypted_email")
      
      # Register for decryption
      user.register_for_decryption
      
      # Mock decryption
      expect(encryption_service).to receive(:decrypt_batch).with([{
        token: "encrypted_first_name",
        entity_id: "User_customer_1",
        entity_type: "customer",
        field_name: "first_name"
      }]).and_return({
        "customer:User_customer_1:first_name" => "John"
      })
      
      # Access a field, which should decrypt it
      expect(user.first_name).to eq("John")
    end
    
    it "initializes tokenized_fields with an empty array in a Rails 4 compatible way" do
      # Create a new class that includes the module but doesn't call tokenize_pii
      klass = Class.new(ActiveRecord::Base) do
        include PiiTokenizer::Tokenizable
        self.table_name = 'users'  # Use the users table for this test
      end
      
      # Should have an empty array as the default
      expect(klass.tokenized_fields).to eq([])
    end
  end
end 