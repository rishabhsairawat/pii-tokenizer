require 'spec_helper'

RSpec.describe 'Avoiding duplicate UPDATE statements' do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
  end

  describe 'when updating a model with tokenized fields' do
    it 'performs only one UPDATE for a single field change' do
      # Create a user for testing
      user = User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

      # Initialize token columns
      user.send(:write_attribute, :first_name_token, 'token_for_John')
      user.send(:write_attribute, :last_name_token, 'token_for_Doe')
      user.send(:write_attribute, :email_token, 'token_for_john.doe@example.com')

      # Set up stub for encrypt_batch
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Make sure the model thinks it's persisted
      allow(user).to receive(:persisted?).and_return(true)
      allow(user).to receive(:new_record?).and_return(false)

      # Set up changes tracking for ActiveRecord
      allow(user).to receive(:changes).and_return({
                                                    'first_name' => ['John', 'James']
                                                  })

      # Track update_columns calls
      update_count = 0
      update_args = []

      allow(user).to receive(:update_columns) do |update_hash|
        update_count += 1
        update_args << update_hash
        # Simulate the update
        update_hash.each do |field, value|
          user.send(:write_attribute, field, value)
        end
      end

      # Update first_name
      user.first_name = 'James'

      # Mock the save method to call handle_tokenization directly
      allow(user).to receive(:save) do
        user.send(:handle_tokenization, false)
        true
      end

      # Save the changes
      user.save

      # Verify only one update occurred
      expect(update_count).to eq(1), "Expected 1 update_columns call but got #{update_count}: #{update_args.inspect}"
    end

    it 'performs only one UPDATE for multiple field changes' do
      # Create a user for testing
      user = User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

      # Initialize token columns
      user.send(:write_attribute, :first_name_token, 'token_for_John')
      user.send(:write_attribute, :last_name_token, 'token_for_Doe')
      user.send(:write_attribute, :email_token, 'token_for_john.doe@example.com')

      # Set up stub for encrypt_batch
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Make sure the model thinks it's persisted
      allow(user).to receive(:persisted?).and_return(true)
      allow(user).to receive(:new_record?).and_return(false)

      # Set up changes tracking for ActiveRecord
      allow(user).to receive(:changes).and_return({
                                                    'first_name' => ['John', 'James'],
                                                    'last_name' => ['Doe', 'Smith'],
                                                    'email' => ['john.doe@example.com', 'james.smith@example.com']
                                                  })

      # Track update_columns calls
      update_count = 0
      update_args = []

      allow(user).to receive(:update_columns) do |update_hash|
        update_count += 1
        update_args << update_hash
        # Simulate the update
        update_hash.each do |field, value|
          user.send(:write_attribute, field, value)
        end
      end

      # Update the fields
      user.first_name = 'James'
      user.last_name = 'Smith'
      user.email = 'james.smith@example.com'

      # Mock the save method to call handle_tokenization directly
      allow(user).to receive(:save) do
        user.send(:handle_tokenization, false)
        true
      end

      # Save the changes
      user.save

      # Verify only one update occurred
      expect(update_count).to eq(1), "Expected 1 update_columns call but got #{update_count}: #{update_args.inspect}"
    end

    it 'performs only one UPDATE when setting a field to nil' do
      # Create a user for testing
      user = User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

      # Initialize token columns
      user.send(:write_attribute, :first_name_token, 'token_for_John')
      user.send(:write_attribute, :last_name_token, 'token_for_Doe')
      user.send(:write_attribute, :email_token, 'token_for_john.doe@example.com')

      # Set up stub for encrypt_batch (but it shouldn't be called for nil)
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Make sure the model thinks it's persisted
      allow(user).to receive(:persisted?).and_return(true)
      allow(user).to receive(:new_record?).and_return(false)

      # Set up changes tracking for ActiveRecord
      allow(user).to receive(:changes).and_return({
                                                    'first_name' => ['John', nil]
                                                  })

      # Track update_columns calls
      update_count = 0
      update_args = []

      allow(user).to receive(:update_columns) do |update_hash|
        update_count += 1
        update_args << update_hash
        # Simulate the update
        update_hash.each do |field, value|
          user.send(:write_attribute, field, value)
        end
      end

      # Update the field to nil
      user.first_name = nil

      # Mock the save method to call handle_tokenization directly
      allow(user).to receive(:save) do
        user.send(:handle_tokenization, false)
        true
      end

      # Save the changes
      user.save

      # Verify only one update occurred
      expect(update_count).to eq(1), "Expected 1 update_columns call but got #{update_count}: #{update_args.inspect}"
    end

    it 'performs only one UPDATE when mixing nil and non-nil updates' do
      # Create a user for testing
      user = User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

      # Initialize token columns
      user.send(:write_attribute, :first_name_token, 'token_for_John')
      user.send(:write_attribute, :last_name_token, 'token_for_Doe')
      user.send(:write_attribute, :email_token, 'token_for_john.doe@example.com')

      # Set up stub for encrypt_batch
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Make sure the model thinks it's persisted
      allow(user).to receive(:persisted?).and_return(true)
      allow(user).to receive(:new_record?).and_return(false)

      # Set up changes tracking for ActiveRecord
      allow(user).to receive(:changes).and_return({
                                                    'first_name' => ['John', nil],
                                                    'last_name' => ['Doe', 'Smith']
                                                  })

      # Track update_columns calls
      update_count = 0
      update_args = []

      allow(user).to receive(:update_columns) do |update_hash|
        update_count += 1
        update_args << update_hash
        # Simulate the update
        update_hash.each do |field, value|
          user.send(:write_attribute, field, value)
        end
      end

      # Update the fields
      user.first_name = nil
      user.last_name = 'Smith'

      # Mock the save method to call handle_tokenization directly
      allow(user).to receive(:save) do
        user.send(:handle_tokenization, false)
        true
      end

      # Save the changes
      user.save

      # Verify only one update occurred
      expect(update_count).to eq(1), "Expected 1 update_columns call but got #{update_count}: #{update_args.inspect}"
    end

    it 'performs only one UPDATE in dual_write mode' do
      # Create a test class directly rather than using a mock
      dual_write_class = Class.new(ActiveRecord::Base) do
        self.table_name = 'users'
        include PiiTokenizer::Tokenizable

        tokenize_pii fields: {
          first_name: 'FIRST_NAME',
          last_name: 'LAST_NAME',
          email: 'EMAIL'
        },
                     entity_type: 'customer',
                     entity_id: ->(record) { "DualWriteUser_#{record.id}" },
                     dual_write: true,
                     read_from_token: false
      end

      # Create an instance of the dual write class
      dual_write_user = dual_write_class.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')

      # Make sure the model thinks it's persisted
      allow(dual_write_user).to receive(:persisted?).and_return(true)
      allow(dual_write_user).to receive(:new_record?).and_return(false)

      # Set up changes tracking for ActiveRecord
      allow(dual_write_user).to receive(:changes).and_return({
                                                               'first_name' => ['John', 'James'],
                                                               'last_name' => ['Doe', 'Smith']
                                                             })

      # Set up stub for encrypt_batch
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Track update_columns calls
      update_count = 0
      update_args = []

      allow(dual_write_user).to receive(:update_columns) do |update_hash|
        update_count += 1
        update_args << update_hash
        # Simulate the update
        update_hash.each do |field, value|
          dual_write_user.send(:write_attribute, field, value)
        end
      end

      # Update the fields
      dual_write_user.first_name = 'James'
      dual_write_user.last_name = 'Smith'

      # Mock the save method to call handle_tokenization directly
      allow(dual_write_user).to receive(:save) do
        dual_write_user.send(:handle_tokenization, false)
        true
      end

      # Save the changes
      dual_write_user.save

      # Verify only one update occurred
      expect(update_count).to eq(1), "Expected 1 update_columns call but got #{update_count}: #{update_args.inspect}"
    end
  end
end
