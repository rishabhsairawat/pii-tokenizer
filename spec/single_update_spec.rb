require 'spec_helper'

RSpec.describe 'Single UPDATE behavior' do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    # Create the tables for all test cases
    User.delete_all

    # Set up generic stubs for the encryption service
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
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
        if token.to_s.start_with?('token_for_')
          value = token.sub('token_for_', '')
          result[token] = value
        end
      end
      result
    end
  end

  # Helper method to create a test class with a clean state
  def create_test_class(dual_write: false)
    Class.new(ActiveRecord::Base) do
      self.table_name = 'users'
      include PiiTokenizer::Tokenizable

      # Configure tokenization
      tokenize_pii fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
                   entity_type: 'test',
                   entity_id: ->(record) { "TEST_#{record.id}" },
                   dual_write: dual_write,
                   read_from_token: !dual_write
    end
  end

  # Test creating a new record - should only have an INSERT, no UPDATE
  it 'performs no UPDATE statements when creating a new record' do
    test_class = create_test_class
    record = test_class.new(id: 1)

    # Capture all SQL queries
    queries = []
    callback = lambda { |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql].present?
    }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      record.email = 'test@example.com'
      record.save!
    end

    # Count the different types of queries
    insert_count = queries.count { |sql| sql.downcase.start_with?('insert') }
    update_count = queries.count { |sql| sql.downcase.start_with?('update') }

    # We should see exactly one INSERT and no UPDATE statements
    expect(insert_count).to eq(1), "Expected 1 INSERT but got #{insert_count}"
    expect(update_count).to eq(0), "Expected 0 UPDATEs but got #{update_count}:\n#{queries.select { |q| q.downcase.start_with?('update') }.join("\n")}"
  end

  # Test updating an existing record - should have exactly one UPDATE
  it 'performs only one UPDATE statement when modifying an existing record' do
    test_class = create_test_class

    # First create the record outside of our SQL tracking
    record = test_class.create!(id: 2, email: 'original@example.com')

    # Capture all SQL queries
    queries = []
    callback = lambda { |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql].present?
    }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      record.email = 'updated@example.com'
      record.save!
    end

    # Count UPDATE statements
    update_count = queries.count { |sql| sql.downcase.start_with?('update') }

    # We should see exactly one UPDATE statement
    expect(update_count).to eq(1), "Expected 1 UPDATE but got #{update_count}:\n#{queries.select { |q| q.downcase.start_with?('update') }.join("\n")}"
  end

  # Test dual-write mode with an existing record
  it 'performs only one UPDATE statement in dual-write mode' do
    test_class = create_test_class(dual_write: true)

    # First create the record outside of our SQL tracking
    record = test_class.create!(id: 3, email: 'dual@example.com')

    # Capture all SQL queries
    queries = []
    callback = lambda { |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql].present?
    }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      record.email = 'updated-dual@example.com'
      record.save!
    end

    # Count UPDATE statements
    update_count = queries.count { |sql| sql.downcase.start_with?('update') }

    # We should see exactly one UPDATE statement
    expect(update_count).to eq(1), "Expected 1 UPDATE but got #{update_count}:\n#{queries.select { |q| q.downcase.start_with?('update') }.join("\n")}"
  end

  # Test setting a field to nil
  it 'performs only one UPDATE statement when setting a field to nil' do
    test_class = create_test_class

    # First create the record outside of our SQL tracking
    record = test_class.create!(id: 4, email: 'to-be-nulled@example.com')

    # Capture all SQL queries
    queries = []
    callback = lambda { |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql].present?
    }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      record.email = nil
      record.save!
    end

    # Count UPDATE statements
    update_count = queries.count { |sql| sql.downcase.start_with?('update') }

    # We should see exactly one UPDATE statement
    expect(update_count).to eq(1), "Expected 1 UPDATE but got #{update_count}:\n#{queries.select { |q| q.downcase.start_with?('update') }.join("\n")}"
  end
end
