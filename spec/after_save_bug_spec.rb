require 'spec_helper'

RSpec.describe 'PiiTokenizer AfterSave Integration' do
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
      entity_type: 'user_uuid',
      entity_id: ->(record) { "#{record.id}" },
      dual_write: false,
      read_from_token: true
    )
  end

  context 'when entity_id is pre-available (not dependent on record.id)' do
    before do
      # Configure with pre-available entity_id and dual_write=true
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { "fixed_id_123" }, # entity_id is constant, not dependent on record.id
        dual_write: true,
        read_from_token: false
      )
    end

    it 'performs only a single INSERT operation with tokens included' do
      # Create a test user with minimal mocking
      user = User.new(first_name: 'Jane', last_name: 'Smith', email: 'jane.smith@example.com')

      # Setup basic encryption service stub
      allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Track SQL queries to verify behavior
      sql_queries = []
      ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
        # Skip schema queries and transaction statements
        unless payload[:sql].match?(/SCHEMA|sqlite_master|BEGIN|COMMIT|SAVEPOINT/)
          sql_queries << payload[:sql]
        end
      end

      # Save the user to trigger callbacks
      user.save!

      # Verify token values were set in memory
      expect(user.first_name_token).to eq('token_for_Jane')
      expect(user.last_name_token).to eq('token_for_Smith')
      expect(user.email_token).to eq('token_for_jane.smith@example.com')

      # Verify original values are preserved in dual-write mode
      expect(user.first_name).to eq('Jane')
      expect(user.last_name).to eq('Smith')
      expect(user.email).to eq('jane.smith@example.com')

      # Since entity_id is pre-available, tokens should be generated before the INSERT
      # and included in the INSERT query
      insert_queries = sql_queries.select { |sql| sql.include?('INSERT') }
      update_queries = sql_queries.select { |sql| sql.include?('UPDATE') }
      
      expect(insert_queries.size).to eq(1), "Expected 1 INSERT query but got #{insert_queries.size}"
      expect(update_queries.size).to eq(0), "Expected 0 UPDATE queries but got #{update_queries.size}"
      
      # Clean up subscription
      ActiveSupport::Notifications.unsubscribe('sql.active_record')
    end
  end

  context 'when entity_id depends on record.id' do
    before do
      # Configure with entity_id dependent on record.id and dual_write=true
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { "#{record.id}" }, # entity_id depends on record.id
        dual_write: true,
        read_from_token: false
      )
    end

    it 'requires two operations (INSERT + UPDATE) to fully tokenize fields' do
      # Create a test user with minimal mocking
      user = User.new(first_name: 'Jane', last_name: 'Smith', email: 'jane.smith@example.com')

      # Setup basic encryption service stub
      allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Track SQL queries to verify behavior
      sql_queries = []
      ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
        # Skip schema queries and transaction statements
        unless payload[:sql].match?(/SCHEMA|sqlite_master|BEGIN|COMMIT|SAVEPOINT/)
          sql_queries << payload[:sql]
        end
      end

      # Save the user to trigger callbacks
      user.save!

      # Verify token values were set in memory
      expect(user.first_name_token).to eq('token_for_Jane')
      expect(user.last_name_token).to eq('token_for_Smith')
      expect(user.email_token).to eq('token_for_jane.smith@example.com')

      # Verify original values are preserved in dual-write mode
      expect(user.first_name).to eq('Jane')
      expect(user.last_name).to eq('Smith')
      expect(user.email).to eq('jane.smith@example.com')

      # Since entity_id depends on record.id, the process requires two steps:
      # 1. INSERT the record to get an ID
      # 2. UPDATE to add the tokens
      insert_queries = sql_queries.select { |sql| sql.include?('INSERT') }
      update_queries = sql_queries.select { |sql| sql.include?('UPDATE') }
      
      expect(insert_queries.size).to eq(1), "Expected 1 INSERT query but got #{insert_queries.size}"
      expect(update_queries.size).to eq(1), "Expected 1 UPDATE query but got #{update_queries.size}"
      
      # Clean up subscription
      ActiveSupport::Notifications.unsubscribe('sql.active_record')
    end
  end

  context 'when dual_write=false' do
    context 'with pre-available entity_id' do
      before do
        # Configure with pre-available entity_id and dual_write=false
        User.tokenize_pii(
          fields: {
            first_name: 'FIRST_NAME',
            last_name: 'LAST_NAME',
            email: 'EMAIL'
          },
          entity_type: 'user_uuid',
          entity_id: ->(record) { "fixed_id_456" }, # entity_id is constant, not dependent on record.id
          dual_write: false,
          read_from_token: true
        )
      end

      it 'performs only a single INSERT operation with tokens included' do
        # Create a test user with minimal mocking
        user = User.new(first_name: 'Jane', last_name: 'Smith', email: 'jane.smith@example.com')

        # Setup basic encryption service stub
        allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
          result = {}
          tokens_data.each do |data|
            key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
            result[key] = "token_for_#{data[:value]}"
          end
          result
        end

        # Track SQL queries to verify behavior
        sql_queries = []
        ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
          # Skip schema queries and transaction statements
          unless payload[:sql].match?(/SCHEMA|sqlite_master|BEGIN|COMMIT|SAVEPOINT/)
            sql_queries << payload[:sql]
          end
        end

        # Save the user to trigger callbacks
        user.save!

        # Verify token values were set in memory
        expect(user.first_name_token).to eq('token_for_Jane')
        expect(user.last_name_token).to eq('token_for_Smith')
        expect(user.email_token).to eq('token_for_jane.smith@example.com')

        # Force a reload to ensure we're seeing the database values
        user.reload

        # In dual_write=false mode, original fields should be nil
        expect(user.read_attribute(:first_name)).to be_nil
        expect(user.read_attribute(:last_name)).to be_nil
        expect(user.read_attribute(:email)).to be_nil

        # But accessor methods should return decrypted values
        expect(user.first_name).to eq('Jane')
        expect(user.last_name).to eq('Smith')
        expect(user.email).to eq('jane.smith@example.com')

        # Since entity_id is pre-available, should be a single INSERT query
        insert_queries = sql_queries.select { |sql| sql.include?('INSERT') }
        update_queries = sql_queries.select { |sql| sql.include?('UPDATE') }
        
        expect(insert_queries.size).to eq(1), "Expected 1 INSERT query but got #{insert_queries.size}"
        expect(update_queries.size).to eq(0), "Expected 0 UPDATE queries but got #{update_queries.size}"
        
        # Clean up subscription
        ActiveSupport::Notifications.unsubscribe('sql.active_record')
      end
    end

    context 'with entity_id dependent on record.id' do
      before do
        # Configure with entity_id dependent on record.id and dual_write=false
        User.tokenize_pii(
          fields: {
            first_name: 'FIRST_NAME',
            last_name: 'LAST_NAME',
            email: 'EMAIL'
          },
          entity_type: 'user_uuid',
          entity_id: ->(record) { "#{record.id}" }, # entity_id depends on record.id
          dual_write: false,
          read_from_token: true
        )
      end

      it 'requires two operations (INSERT + UPDATE) to fully tokenize fields' do
        # Create a test user with minimal mocking
        user = User.new(first_name: 'Jane', last_name: 'Smith', email: 'jane.smith@example.com')

        # Setup basic encryption service stub
        allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch) do |tokens_data|
          result = {}
          tokens_data.each do |data|
            key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
            result[key] = "token_for_#{data[:value]}"
          end
          result
        end

        # Track SQL queries to verify behavior
        sql_queries = []
        ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
          # Skip schema queries and transaction statements
          unless payload[:sql].match?(/SCHEMA|sqlite_master|BEGIN|COMMIT|SAVEPOINT/)
            sql_queries << payload[:sql]
          end
        end

        # Save the user to trigger callbacks
        user.save!

        # Verify token values were set in memory
        expect(user.first_name_token).to eq('token_for_Jane')
        expect(user.last_name_token).to eq('token_for_Smith')
        expect(user.email_token).to eq('token_for_jane.smith@example.com')

        # Force a reload to ensure we're seeing the database values
        user.reload

        # In dual_write=false mode, original fields should be nil
        expect(user.read_attribute(:first_name)).to be_nil
        expect(user.read_attribute(:last_name)).to be_nil
        expect(user.read_attribute(:email)).to be_nil

        # But accessor methods should return decrypted values
        expect(user.first_name).to eq('Jane')
        expect(user.last_name).to eq('Smith')
        expect(user.email).to eq('jane.smith@example.com')

        # Since entity_id depends on record.id, the process requires two steps:
        # 1. INSERT the record to get an ID
        # 2. UPDATE to add the tokens
        insert_queries = sql_queries.select { |sql| sql.include?('INSERT') }
        update_queries = sql_queries.select { |sql| sql.include?('UPDATE') }
        
        expect(insert_queries.size).to eq(1), "Expected 1 INSERT query but got #{insert_queries.size}"
        expect(update_queries.size).to eq(1), "Expected 1 UPDATE query but got #{update_queries.size}"
        
        # Clean up subscription
        ActiveSupport::Notifications.unsubscribe('sql.active_record')
      end
    end
  end
end
