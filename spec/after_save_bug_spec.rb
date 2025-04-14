require 'spec_helper'

RSpec.describe "PiiTokenizer AfterSave Integration" do
  before do
    # Clear DB
    User.delete_all
  end

  after do
    # Reset to default configuration
    User.tokenize_pii(
      fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
      entity_type: 'customer',
      entity_id: ->(record) { "User_customer_#{record.id}" },
      dual_write: false,
      read_from_token: true
    )
  end

  context "when dual_write=true" do
    before do
      # Configure with dual_write=true and read_from_token=false
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'customer',
        entity_id: ->(record) { "User_customer_#{record.id}" },
        dual_write: true,
        read_from_token: false
      )
    end

    it "persists token values while preserving original fields" do
      # Create a test user with minimal mocking
      user = User.new(first_name: "Jane", last_name: "Smith", email: "jane.smith@example.com")
      
      # Setup basic encryption service stub
      allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end
      
      # Spy on the update_all method to see what's being sent to the database
      updates_sent = nil
      allow(User).to receive(:unscoped).and_return(User)
      allow(User).to receive(:where).and_return(User)
      allow(User).to receive(:update_all) do |updates|
        updates_sent = updates
        true
      end
      
      # Save the user to trigger callbacks
      user.save!
      
      # Verify token values were set in memory
      expect(user.first_name_token).to eq("token_for_Jane")
      expect(user.last_name_token).to eq("token_for_Smith")
      expect(user.email_token).to eq("token_for_jane.smith@example.com")
      
      # Verify original values are preserved in dual-write mode
      expect(user.first_name).to eq("Jane")
      expect(user.last_name).to eq("Smith")
      expect(user.email).to eq("jane.smith@example.com")
      
      # Verify that database updates include token columns
      expect(updates_sent).to be_present
      expect(updates_sent.keys).to include("first_name_token", "last_name_token", "email_token")
      expect(updates_sent["first_name_token"]).to eq("token_for_Jane")
    end
  end

  context "when dual_write=false" do
    before do
      # Configure with dual_write=false
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'customer',
        entity_id: ->(record) { "User_customer_#{record.id}" },
        dual_write: false,
        read_from_token: true
      )
    end

    it "persists token values and clears original fields" do
      # Create a test user with minimal mocking
      user = User.new(first_name: "Jane", last_name: "Smith", email: "jane.smith@example.com")
      
      # Setup basic encryption service stub
      allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end
      
      # Spy on the update_all method to see what's being sent to the database
      updates_sent = nil
      allow(User).to receive(:unscoped).and_return(User)
      allow(User).to receive(:where).and_return(User)
      allow(User).to receive(:update_all) do |updates|
        updates_sent = updates
        true
      end
      
      # Save the user to trigger callbacks
      user.save!
      
      # Verify token values were set in memory and original fields are nil
      expect(user.first_name_token).to eq("token_for_Jane")
      expect(user.last_name_token).to eq("token_for_Smith")
      expect(user.email_token).to eq("token_for_jane.smith@example.com")
      
      # In dual_write=false mode, original fields should be nil
      expect(user.read_attribute(:first_name)).to be_nil
      expect(user.read_attribute(:last_name)).to be_nil
      expect(user.read_attribute(:email)).to be_nil
      
      # Verify the database updates include token columns and nil original fields
      expect(updates_sent).to be_present
      expect(updates_sent.keys).to include("first_name_token", "last_name_token", "email_token")
      expect(updates_sent.keys).to include("first_name", "last_name", "email")
      expect(updates_sent["first_name_token"]).to eq("token_for_Jane")
      expect(updates_sent["first_name"]).to be_nil
    end
  end
end 