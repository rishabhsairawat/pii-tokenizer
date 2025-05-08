require 'spec_helper'

RSpec.describe 'Rails version compatibility' do
  include_context 'tokenization test helpers'

  before do
    User.delete_all

    # Track SQL queries
    @sql_queries = []
    ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
      # Skip schema queries
      unless payload[:sql].include?('SCHEMA') || payload[:sql].include?('sqlite_master')
        @sql_queries << payload[:sql]
      end
    end
  end

  after do
    ActiveSupport::Notifications.unsubscribe('sql.active_record')
  end

  context 'with dual_write=true' do
    before do
      # Configure with dual_write=true, read_from_token=false
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { record.id.to_s },
        dual_write: true,
        read_from_token: false
      )
    end

    it 'creates a record with tokens and avoids redundant database updates' do
      # Set up batch encryption expectation with real response format
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Create a new user
      user = User.create!(
        first_name: 'Jane',
        last_name: 'Smith',
        email: 'jane.smith@example.com'
      )

      # Verify token values were set correctly
      expect(user.first_name_token).to eq('token_for_Jane')
      expect(user.last_name_token).to eq('token_for_Smith')
      expect(user.email_token).to eq('token_for_jane.smith@example.com')

      # Check original values are preserved in dual_write=true mode
      expect(user.first_name).to eq('Jane')
      expect(user.last_name).to eq('Smith')
      expect(user.email).to eq('jane.smith@example.com')

      # Verify the SQL queries count is appropriate for the Rails version
      insert_queries = @sql_queries.select { |q| q.include?('INSERT') }
      update_queries = @sql_queries.select { |q| q.include?('UPDATE') }

      # In both Rails 4 and 5, we should have exactly 1 INSERT query
      expect(insert_queries.size).to eq(1)

      # The number of UPDATE queries varies by Rails version and implementation
      if ActiveRecord::VERSION::MAJOR >= 5
        # In Rails 5, with the token memory tracking, we should have at most 1 UPDATE query
        expect(update_queries.size).to be <= 1
      else
        # In Rails 4, we should have exactly 1 UPDATE queries at most
        # 1 update after save for token fields
        # But in our optimized version, if the tokens are already set, we might have 0
        expect(update_queries.size).to be <= 1
      end
    end
  end

  context 'with dual_write=false' do
    before do
      # Configure with dual_write=false
      User.tokenize_pii(
        fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
        entity_type: 'user_uuid',
        entity_id: ->(record) { record.id.to_s },
        dual_write: false,
        read_from_token: true
      )
    end

    it 'creates a record with tokens and clears original fields' do
      # Set up batch encryption expectation
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Create a new user
      user = User.create!(
        first_name: 'Jane',
        last_name: 'Smith',
        email: 'jane.smith@example.com'
      )

      # Verify token values were set correctly
      expect(user.first_name_token).to eq('token_for_Jane')
      expect(user.last_name_token).to eq('token_for_Smith')
      expect(user.email_token).to eq('token_for_jane.smith@example.com')

      # Reload to ensure we're getting values from database
      user.reload

      # In dual_write=false mode, original fields should be nil
      expect(user.read_attribute(:first_name)).to be_nil
      expect(user.read_attribute(:last_name)).to be_nil
      expect(user.read_attribute(:email)).to be_nil

      # But accessor methods should return decrypted values when read_from_token=true
      expect(user.first_name).to eq('Jane')
      expect(user.last_name).to eq('Smith')
      expect(user.email).to eq('jane.smith@example.com')

      # Verify the SQL queries count is appropriate for the Rails version
      insert_queries = @sql_queries.select { |q| q.include?('INSERT') }
      update_queries = @sql_queries.select { |q| q.include?('UPDATE') }

      # In both Rails 4 and 5, we should have exactly 1 INSERT query
      expect(insert_queries.size).to eq(1)

      # The number of UPDATE queries varies by Rails version
      if ActiveRecord::VERSION::MAJOR >= 5
        # In Rails 5, we should have at most 1 UPDATE query
        expect(update_queries.size).to be <= 1
      else
        # In Rails 4, we should have at most 1 UPDATE query with our optimization
        expect(update_queries.size).to be <= 1
      end
    end
  end

  context 'when handling changes in different Rails versions' do
    let(:user) { User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john@example.com') }

    before do
      # Mock the encryption service
      allow(PiiTokenizer.encryption_service).to receive(:encrypt_batch).and_return({})

      # Make user appear persisted
      allow(user).to receive(:persisted?).and_return(true)
      allow(user).to receive(:new_record?).and_return(false)

      # Clear instance variables
      user.instance_variable_set(:@tokenization_state, nil)
    end

    it 'handles field_changed? in both Rails 4 and 5' do
      # Test the field_changed? method
      if ::ActiveRecord::VERSION::MAJOR >= 5
        allow(user).to receive(:previous_changes).and_return('first_name' => ['Old', 'New'])
        expect(user.send(:field_changed?, 'first_name')).to be true
        expect(user.send(:field_changed?, 'age')).to be false
      else
        allow(user).to receive(:changes).and_return('first_name' => ['Old', 'New'])
        expect(user.send(:field_changed?, 'first_name')).to be true
        expect(user.send(:field_changed?, 'age')).to be false
      end
    end

    it 'handles active_changes in both Rails 4 and 5' do
      changes_hash = { 'first_name' => ['Old', 'New'] }

      if ::ActiveRecord::VERSION::MAJOR >= 5
        allow(user).to receive(:previous_changes).and_return(changes_hash)
        expect(user.send(:active_changes)).to eq(changes_hash)
      else
        allow(user).to receive(:changes).and_return(changes_hash)
        expect(user.send(:active_changes)).to eq(changes_hash)
      end
    end

    it 'handles is_new_record check in process_after_save_tokenization' do
      # In process_after_save_tokenization, we check if a record is new based on changes
      if ::ActiveRecord::VERSION::MAJOR >= 5
        # In Rails 5, new records should have 'id' in previous_changes
        allow(user).to receive(:previous_changes).and_return('id' => [nil, 1])
        expect(user.send(:field_changed?, 'id')).to be true
      else
        # In Rails 4, new records should have 'id' in changes
        allow(user).to receive(:changes).and_return('id' => [nil, 1])
        expect(user.send(:field_changed?, 'id')).to be true
      end
    end

    it 'correctly falls back to empty hash when changes methods are missing' do
      # Test fallback behavior
      allow(user).to receive(:respond_to?).with(:previous_changes).and_return(false)
      allow(user).to receive(:respond_to?).with(:changes).and_return(false)

      expect(user.send(:active_changes)).to eq({})
    end
  end
end
