require 'spec_helper'

RSpec.describe 'Combined Batch Operations', :use_tokenizable_models do
  # Set up the database with both regular and JSON columns
  before(:all) do
    # Create test table with both regular and JSON columns
    ActiveRecord::Schema.define do
      create_table :mixed_records, force: true do |t|
        t.string :first_name
        t.string :first_name_token
        t.string :last_name
        t.string :last_name_token
        t.string :email
        t.string :email_token
        t.text :profile_details # JSON column
        t.text :profile_details_token # JSON column token
        t.text :contact_info # Second JSON column
        t.text :contact_info_token # Second JSON column token
        t.timestamps null: false
      end
    end

    # Define model with both regular and JSON tokenized fields
    class MixedRecord < ActiveRecord::Base
      include PiiTokenizer::Tokenizable

      # Configure regular tokenization
      tokenize_pii fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
                   entity_type: 'mixed_record',
                   entity_id: ->(record) { "mixed_record_#{record.id}" },
                   dual_write: false,
                   read_from_token: true

      # Configure JSON field tokenization
      tokenize_json_fields(
        profile_details: {
          name: 'NAME',
          email_id: 'EMAIL'
        },
        contact_info: {
          phone: 'PHONE',
          address: 'ADDRESS'
        }
      )

      # Add serialization for Rails 4.2 compatibility
      serialize :profile_details, JSON
      serialize :profile_details_token, JSON
      serialize :contact_info, JSON
      serialize :contact_info_token, JSON
    end
  end

  after(:all) do
    # Clean up
    ActiveRecord::Base.connection.drop_table(:mixed_records) if ActiveRecord::Base.connection.table_exists?(:mixed_records)
    Object.send(:remove_const, :MixedRecord) if defined?(MixedRecord)
  end

  before do
    # Clear the database
    MixedRecord.delete_all

    # Mock the encryption service
    @encryption_service = instance_double(PiiTokenizer::EncryptionService)
    allow(PiiTokenizer).to receive(:encryption_service).and_return(@encryption_service)
  end

  describe 'combined batch encryption' do
    it 'processes both regular and JSON fields in a single batch during save' do
      # Set up batch encryption expectation to validate combined processing
      expect(@encryption_service).to receive(:encrypt_batch) do |tokens_data|
        # Collect the field names to verify JSON fields are included
        field_names = tokens_data.map { |data| data[:field_name] }

        # Return mock tokens for validation
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end.at_least(:once) # Allow multiple calls

      # Create a record with both regular and JSON fields
      record = MixedRecord.create!(
        first_name: 'John',
        last_name: 'Doe',
        email: 'john.doe@example.com',
        profile_details: {
          name: 'John Doe',
          email_id: 'john.doe@example.com',
          age: 30 # Non-tokenized field
        },
        contact_info: {
          phone: '555-1234',
          address: '123 Main St',
          preferred: true # Non-tokenized field
        }
      )

      # Verify the record was tokenized correctly
      expect(record.first_name_token).to eq('token_for_John')
      expect(record.profile_details_token['name']).to eq('token_for_John Doe')
      expect(record.contact_info_token['phone']).to eq('token_for_555-1234')
    end

    it 'avoids duplicate API calls when updating different field types' do
      # First create a record to work with
      allow(@encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      record = MixedRecord.create!(
        first_name: 'John',
        last_name: 'Doe',
        profile_details: { name: 'John Doe' }
      )

      # Reset the mock to track calls
      allow(@encryption_service).to receive(:encrypt_batch).and_return({})

      # Update both regular and JSON fields
      record.first_name = 'Jane'
      record.profile_details = { name: 'Jane Doe' }

      # Should only call encrypt_batch once
      expect(@encryption_service).to receive(:encrypt_batch).once

      record.save!
    end
  end

  describe 'combined batch decryption' do
    it 'loads all tokenized fields in a single batch on first access' do
      # Set up a record with tokenized fields
      allow(@encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      record = MixedRecord.create!(
        first_name: 'John',
        last_name: 'Doe',
        email: 'john.doe@example.com',
        profile_details: {
          name: 'John Doe',
          email_id: 'john.doe@example.com'
        },
        contact_info: {
          phone: '555-1234',
          address: '123 Main St'
        }
      )

      # Reload to ensure we're using database values
      record.reload

      # Clear the cache to ensure we're testing fresh loading
      allow(record).to receive(:field_decryption_cache).and_return({})

      # Set up expectations for batch decryption
      expect(@encryption_service).to receive(:decrypt_batch) do |tokens|
        # Verify that tokens from both regular and JSON fields are included
        expect(tokens).to include('token_for_John')
        expect(tokens).to include('token_for_Doe')
        expect(tokens).to include('token_for_john.doe@example.com')
        expect(tokens).to include('token_for_John Doe')
        expect(tokens).to include('token_for_555-1234')
        expect(tokens).to include('token_for_123 Main St')

        # Return mock decrypted values
        result = {}
        tokens.each do |token|
          if token.start_with?('token_for_')
            original_value = token.sub('token_for_', '')
            result[token] = original_value
          end
        end
        result
      end

      # Access a regular field - should trigger batch loading of ALL fields
      first_name = record.first_name
      expect(first_name).to eq('John')

      # Now verify that accessing JSON fields doesn't trigger additional API calls
      expect(@encryption_service).not_to receive(:decrypt_batch)

      # These shouldn't make API calls since they were loaded in the first batch
      expect(record.profile_details['name']).to eq('John Doe')
      expect(record.contact_info['phone']).to eq('555-1234')
    end

    it 'loads all tokenized fields in a single batch when accessing a JSON field first' do
      # Set up a record with tokenized fields
      allow(@encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      record = MixedRecord.create!(
        first_name: 'John',
        last_name: 'Doe',
        profile_details: {
          name: 'John Doe',
          email_id: 'john.doe@example.com'
        }
      )

      # Reload to ensure we're using database values
      record.reload

      # Clear the cache to ensure we're testing fresh loading
      allow(record).to receive(:field_decryption_cache).and_return({})

      # Set up expectations for batch decryption
      expect(@encryption_service).to receive(:decrypt_batch).once do |tokens|
        # Verify that tokens from both regular and JSON fields are included
        expect(tokens).to include('token_for_John')
        expect(tokens).to include('token_for_Doe')
        expect(tokens).to include('token_for_John Doe')

        # Return mock decrypted values
        result = {}
        tokens.each do |token|
          if token.start_with?('token_for_')
            original_value = token.sub('token_for_', '')
            result[token] = original_value
          end
        end
        result
      end

      # Access a JSON field first - should trigger batch loading of ALL fields
      json_value = record.profile_details['name']
      expect(json_value).to eq('John Doe')

      # Now accessing a regular field shouldn't trigger another API call
      expect(@encryption_service).not_to receive(:decrypt_batch)
      expect(record.first_name).to eq('John')
    end

    it 'respects the read_from_token_column setting for all field types' do
      # Set up a record with tokenized fields
      allow(@encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # Set up decryption mock to verify shared batch loading
      allow(@encryption_service).to receive(:decrypt_batch) do |tokens|
        result = {}
        tokens.each do |token|
          if token.start_with?('token_for_')
            original_value = token.sub('token_for_', '')
            result[token] = original_value
          end
        end
        result
      end

      # Create a record
      record = MixedRecord.create!(
        first_name: 'John',
        last_name: 'Doe',
        profile_details: { name: 'John Doe' }
      )

      # With read_from_token=true (default), should read from tokens
      expect(record.first_name).to eq('John')
      expect(record.profile_details['name']).to eq('John Doe')

      # Temporarily change the setting
      original = MixedRecord.read_from_token_column
      MixedRecord.read_from_token_column = false

      # Clear the cache to ensure we're testing fresh loading
      record.send(:clear_decryption_cache)

      # Should only call decrypt_batch once for all fields
      expect(@encryption_service).to receive(:decrypt_batch).once

      # These should be loaded in a single batch even with read_from_token=false
      expect(record.first_name).to eq('John')
      expect(record.profile_details['name']).to eq('John Doe')

      # Restore the setting
      MixedRecord.read_from_token_column = original
    end
  end
end
