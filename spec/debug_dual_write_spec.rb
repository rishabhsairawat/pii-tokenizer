require 'spec_helper'

RSpec.describe 'PiiTokenizer DualWrite Integration' do
  # Create a clean test database environment
  before do
    # Clear DB
    User.delete_all

    # Create a real database connection to track SQL queries
    @sql_queries = []
    ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      # Skip uninteresting SQL like schema queries
      unless payload[:sql].match?(/SCHEMA|sqlite_master|BEGIN|COMMIT/)
        @sql_queries << payload[:sql]
      end
    end
  end

  after do
    # Reset User configuration
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

    # Clear subscription
    ActiveSupport::Notifications.unsubscribe('sql.active_record')
  end

  # Define a custom Log class with dual_write=true and read_from_token=false
  before do
    # Define the Log class
    class Log < ActiveRecord::Base
      include PiiTokenizer::Tokenizable

      connection.create_table :logs, force: true do |t|
        t.string :message
        t.string :message_token
        t.timestamps null: false
      end

      # Configure tokenization
      tokenize_pii(
        fields: { message: 'MESSAGE' },
        entity_type: 'log',
        entity_id: ->(record) { "Log_#{record.id}" },
        dual_write: true,
        read_from_token: false
      )
    end
  end

  after do
    # Clean up
    Object.send(:remove_const, :Log) if Object.const_defined?(:Log)
  end

  describe 'with real encryption service' do
    before do
      # Configure PiiTokenizer to use a real encryption service
      # that behaves similarly to the actual service
      config = PiiTokenizer::Configuration.new
      config.encryption_service_url = 'http://mock-service.example.com'
      allow(PiiTokenizer).to receive(:configuration).and_return(config)

      # Create a real encryption service that just returns deterministic tokens
      encryption_service = PiiTokenizer::EncryptionService.new(config)

      # Override the API methods to simulate behavior without network calls
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      allow(encryption_service).to receive(:decrypt_batch) do |tokens|
        result = {}
        tokens.each do |token|
          next unless token.to_s.start_with?('token_for_')

          original_value = token.to_s.sub('token_for_', '')
          result[token] = original_value
        end
        result
      end

      allow(encryption_service).to receive(:search_tokens) do |value|
        ["token_for_#{value}"]
      end

      allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
    end

    context 'new + save pattern' do
      it 'correctly persists tokens with dual_write=true, read_from_token=false' do
        @sql_queries.clear # Reset SQL query tracking

        # Configure User with dual_write=true, read_from_token=false
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

        # Test new + save
        user = User.new(first_name: 'Jane', last_name: 'Smith', email: 'jane.smith@example.com')
        user.save!

        # Reload user from database to verify what was actually saved
        user_from_db = User.find(user.id)

        # Verify in-memory values are correct
        expect(user.first_name).to eq('Jane')
        expect(user.first_name_token).to eq('token_for_Jane')
        expect(user.last_name).to eq('Smith')
        expect(user.last_name_token).to eq('token_for_Smith')

        # Verify database values are correct
        expect(user_from_db.read_attribute(:first_name)).to eq('Jane')
        expect(user_from_db.read_attribute(:first_name_token)).to eq('token_for_Jane')
        expect(user_from_db.read_attribute(:last_name)).to eq('Smith')
        expect(user_from_db.read_attribute(:last_name_token)).to eq('token_for_Smith')

        # With our simplified approach, all tokenization happens in one step (INSERT)
        insert_index = @sql_queries.find_index { |sql| sql.include?('INSERT INTO') }
        expect(insert_index).not_to be_nil, 'No INSERT SQL was executed'

        # Check if the INSERT statement includes token columns
        expect(@sql_queries[insert_index]).to include('_token')
      end
    end

    context 'create method pattern' do
      it 'correctly persists tokens with new records using create!' do
        @sql_queries.clear

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

        # Test direct create method (alternative to new + save)
        user = User.create!(first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

        # Reload user from database
        user_from_db = User.find(user.id)

        # Verify database values are correct
        expect(user_from_db.read_attribute(:first_name)).to eq('John')
        expect(user_from_db.read_attribute(:first_name_token)).to eq('token_for_John')

        # With our simplified approach, tokens are set directly in the INSERT
        token_in_insert = @sql_queries.any? { |sql| sql.include?('INSERT') && sql.include?('_token') }
        expect(token_in_insert).to be(true)
      end
    end

    context 'class after_save callback' do
      it 'verifies no after_save callback is registered anymore' do
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

        # Get the after_save callbacks for the User class
        callbacks = []
        if User.respond_to?(:_save_callbacks)
          User._save_callbacks.select { |cb| cb.kind == :after }.each do |callback|
            filter = callback.filter
            name = filter.is_a?(Symbol) ? filter.to_s : filter.inspect
            callbacks << name
          end
        end

        # Verify our process_after_save_tokenization callback is NOT registered
        # since we simplified the code to use single-phase tokenization
        expect(callbacks).not_to include('process_after_save_tokenization')
      end
    end

    context 'empty string handling' do
      it 'correctly reads empty string from token column when read_from_token is true' do
        # Configure Log with read_from_token=true
        Log.tokenize_pii(
          fields: { message: 'MESSAGE' },
          entity_type: 'log',
          entity_id: ->(record) { "Log_#{record.id}" },
          dual_write: true,
          read_from_token: true
        )

        # Create a log with empty string
        log = Log.create!(message: '')

        # Verify token column has empty string
        expect(log.message_token).to eq('')

        # Reload from database to ensure we're reading from DB
        log.reload

        # Verify that reading the field returns empty string
        expect(log.message).to eq('')
        expect(log.message_token).to eq('')

        # Verify original column is '' (since dual_write=true)
        expect(log.read_attribute(:message)).to eq('')
      end

      it 'correctly reads empty string from token column when read_from_token is true but dual_write is false' do
        # Configure Log with read_from_token=true
        Log.tokenize_pii(
          fields: { message: 'MESSAGE' },
          entity_type: 'log',
          entity_id: ->(record) { "Log_#{record.id}" },
          dual_write: true,
          read_from_token: true
        )

        # Create a log with empty string
        log = Log.create!(message: 'test')

        Log.tokenize_pii(
          fields: { message: 'MESSAGE' },
          entity_type: 'log',
          entity_id: ->(record) { "Log_#{record.id}" },
          dual_write: false,
          read_from_token: true
        )

        # Verify token column has empty string
        expect(log.message_token).to eq('token_for_test')

        log.message = ''
        log.save!
        # Reload from database to ensure we're reading from DB
        log.reload

        # Verify that reading the field returns empty string
        expect(log.message).to eq('')
        expect(log.message_token).to eq('')

        # Verify original column is '' (since dual_write=true)
        expect(log.read_attribute(:message)).to eq('test')
      end
    end
  end
end
