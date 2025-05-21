require 'spec_helper'

# This test specifically focuses on the fix for the tokenization bug in after_save
# where entity_id is available only after the record is saved
RSpec.describe 'PiiTokenizer AfterSave Integration' do
  before do
    PiiTokenizer.configure do |config|
      config.encryption_service_url = 'http://example.com'
    end

    # Track SQL queries for this test
    @sql_queries = []
    ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      # Skip schema queries and other unrelated queries
      unless payload[:sql].match?(/SCHEMA|sqlite_master|BEGIN|COMMIT|savepoint/i)
        @sql_queries << payload[:sql]
      end
    end
  end

  after do
    ActiveSupport::Notifications.unsubscribe('sql.active_record')
  end

  describe 'when entity_id depends on record.id' do
    before do
      # Configure user with entity_id that depends on record.id
      User.tokenize_pii(
        fields: {
          first_name: PiiTokenizer::PiiTypes::NAME,
          last_name: PiiTokenizer::PiiTypes::NAME,
          email: PiiTokenizer::PiiTypes::EMAIL
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { "user_#{record.id}" },
        dual_write: true,
        read_from_token: false
      )

      # Create a mock encryption service
      mock_encryption_service = instance_double(PiiTokenizer::EncryptionService)
      allow(mock_encryption_service).to receive(:encrypt_batch) do |tokens_data|
        # Return tokens that match the values
        result = {}
        tokens_data.each do |token_data|
          entity_id = token_data[:entity_id]
          value = token_data[:value]
          key = "#{token_data[:entity_type].upcase}:#{entity_id}:#{token_data[:pii_type]}:#{value}"
          result[key] = "token_for_#{value}"
        end
        result
      end

      allow(mock_encryption_service).to receive(:decrypt_batch) do |tokens|
        # Return decrypted values
        result = {}
        tokens.each do |token|
          if token.start_with?('token_for_')
            value = token.sub('token_for_', '')
            result[token] = value
          end
        end
        result
      end

      allow(PiiTokenizer).to receive(:encryption_service).and_return(mock_encryption_service)
    end

    it 'tokenizes fields in a single operation during save' do
      # Clear SQL queries array to start fresh
      @sql_queries = []

      # Create a new user that will need to have its ID set during save
      user = User.new(
        first_name: 'Jane',
        last_name: 'Smith',
        email: 'jane.smith@example.com'
      )

      # Save the user
      user.save!

      # Reload user from database
      user_from_db = User.find(user.id)

      # Verify token values are correct in the database
      expect(user_from_db.first_name_token).to eq('token_for_Jane')
      expect(user_from_db.last_name_token).to eq('token_for_Smith')
      expect(user_from_db.email_token).to eq('token_for_jane.smith@example.com')

      # Extract SQL queries by type
      insert_queries = @sql_queries.select { |q| q.include?('INSERT') }
      update_queries = @sql_queries.select { |q| q.include?('UPDATE') }

      # We now expect a different behavior with our simplified approach
      # Since entity_id is now guaranteed to be available, we should have
      # all tokenization done in one step
      expect(insert_queries.size).to eq(1), "Expected 1 INSERT query but got #{insert_queries.size}"

      # With our simplified approach, token columns should be set directly in the INSERT
      expect(update_queries.size).to eq(0), "Expected 0 UPDATE queries but got #{update_queries.size}"

      # Check that the first query includes token fields
      expect(insert_queries.first).to include('INSERT INTO')
      expect(insert_queries.first).to include('first_name_token')
      expect(insert_queries.first).to include('last_name_token')
      expect(insert_queries.first).to include('email_token')
    end
  end

  describe 'when dual_write=false with entity_id dependent on record.id' do
    before do
      # Configure user with dual_write=false
      User.tokenize_pii(
        fields: {
          first_name: PiiTokenizer::PiiTypes::NAME,
          last_name: PiiTokenizer::PiiTypes::NAME,
          email: PiiTokenizer::PiiTypes::EMAIL
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { "user_#{record.id}" },
        dual_write: false,
        read_from_token: true
      )

      # Create a mock encryption service
      mock_encryption_service = instance_double(PiiTokenizer::EncryptionService)
      allow(mock_encryption_service).to receive(:encrypt_batch) do |tokens_data|
        # Return tokens that match the values
        result = {}
        tokens_data.each do |token_data|
          entity_id = token_data[:entity_id]
          value = token_data[:value]
          key = "#{token_data[:entity_type].upcase}:#{entity_id}:#{token_data[:pii_type]}:#{value}"
          result[key] = "token_for_#{value}"
        end
        result
      end

      allow(mock_encryption_service).to receive(:decrypt_batch) do |tokens|
        # Return decrypted values
        result = {}
        tokens.each do |token|
          if token.start_with?('token_for_')
            value = token.sub('token_for_', '')
            result[token] = value
          end
        end
        result
      end

      allow(PiiTokenizer).to receive(:encryption_service).and_return(mock_encryption_service)
    end

    it 'tokenizes fields in a single operation during save' do
      # Clear SQL queries array to start fresh
      @sql_queries = []

      # Create a new user
      user = User.new(
        first_name: 'Jane',
        last_name: 'Smith',
        email: 'jane.smith@example.com'
      )

      # Save the user
      user.save!

      # Reload user from database
      user_from_db = User.find(user.id)

      # Verify token values are correct
      expect(user_from_db.first_name_token).to eq('token_for_Jane')
      expect(user_from_db.last_name_token).to eq('token_for_Smith')
      expect(user_from_db.email_token).to eq('token_for_jane.smith@example.com')

      # In dual_write=false mode, original fields should be nil
      expect(user_from_db.read_attribute(:first_name)).to be_nil
      expect(user_from_db.read_attribute(:last_name)).to be_nil
      expect(user_from_db.read_attribute(:email)).to be_nil

      # But accessor methods should return decrypted values when read_from_token=true
      expect(user_from_db.first_name).to eq('Jane')
      expect(user_from_db.last_name).to eq('Smith')
      expect(user_from_db.email).to eq('jane.smith@example.com')

      # Extract SQL queries by type
      insert_queries = @sql_queries.select { |q| q.include?('INSERT') }
      update_queries = @sql_queries.select { |q| q.include?('UPDATE') }

      # We now expect a different behavior with our simplified approach
      # Since entity_id is now guaranteed to be available, we should have
      # all tokenization done in one step
      expect(insert_queries.size).to eq(1), "Expected 1 INSERT query but got #{insert_queries.size}"

      # With our simplified approach, token columns should be set directly in the INSERT
      expect(update_queries.size).to eq(0), "Expected 0 UPDATE queries but got #{update_queries.size}"
    end
  end
end
