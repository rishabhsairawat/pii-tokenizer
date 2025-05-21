require 'spec_helper'

RSpec.describe PiiTokenizer::Tokenizable do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
  end

  describe 'class methods' do
    it 'initializes class variables correctly' do
      # Reset the User class's tokenized fields
      # This is to ensure the test starts with a clean slate
      original_tokenized_fields = User.tokenized_fields.dup
      original_pii_types = User.pii_types.dup

      # Define a new temporary class
      temp_class = Class.new do
        include PiiTokenizer::Tokenizable
      end

      # Test with the temporary class
      expect(temp_class.tokenized_fields).to be_an(Array)
      expect(temp_class.tokenized_fields).to be_empty
      expect(temp_class.pii_types).to be_a(Hash)
      expect(temp_class.pii_types).to be_empty
      expect(temp_class.dual_write_enabled).to be false
      expect(temp_class.read_from_token_column).to be true
    end

    it 'can generate token column name for a field' do
      expect(User.token_column_for(:first_name)).to eq('first_name_token')
      expect(User.token_column_for('first_name')).to eq('first_name_token')
    end
  end

  describe 'find and create methods' do
    let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

    before do
      allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
      User.dual_write_enabled = false
      User.read_from_token_column = true
    end

    it 'handles find_or_initialize_by with tokenized fields' do
      # Set up the encryption service to return a token for the email
      allow(encryption_service).to receive(:search_tokens)
        .with('john.doe@example.com')
        .and_return(['encrypted_email'])

      # Create a relation mock that will be returned by `where`
      relation = double('ActiveRecord::Relation')
      allow(relation).to receive(:first).and_return(nil)

      # Allow where to be called with any arguments as it depends on ActiveRecord internals
      allow(User).to receive(:where).and_return(relation)

      # Mock new to return a user
      new_user = double('User')
      allow(new_user).to receive(:email=).with('john.doe@example.com')
      allow(User).to receive(:new).and_return(new_user)

      # Call the method
      user = User.find_or_initialize_by(email: 'john.doe@example.com')

      # Verify the result is our mocked user
      expect(user).to eq(new_user)
    end

    it 'handles find_or_create_by with tokenized fields' do
      # Set up the encryption service to return a token for the email
      allow(encryption_service).to receive(:search_tokens)
        .with('john.doe@example.com')
        .and_return(['encrypted_email'])

      # Create a relation mock that will be returned by `where`
      relation = double('ActiveRecord::Relation')
      allow(relation).to receive(:first).and_return(nil)

      # Allow where to be called with any arguments as it depends on ActiveRecord internals
      allow(User).to receive(:where).and_return(relation)

      # Mock exists? to prevent reload errors
      allow(User).to receive(:exists?).and_return(false)

      # Mock new to return a user with id for entity_id generation
      new_user = double('User')
      allow(new_user).to receive(:email=).with('john.doe@example.com')
      allow(new_user).to receive(:save).and_return(true)
      allow(new_user).to receive(:id).and_return(1)
      allow(new_user).to receive(:entity_type).and_return('user_uuid')
      allow(new_user).to receive(:entity_id).and_return('User_user_uuid_1')
      allow(new_user).to receive(:persisted?).and_return(true)

      # Since we're potentially using encrypt_batch in the implementation
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      allow(new_user).to receive(:field_decryption_cache).and_return({})
      allow(new_user).to receive(:new_record?).and_return(false)

      # Allow User to get our mock user
      allow(User).to receive(:new).and_return(new_user)

      # Call the method
      user = User.find_or_create_by(email: 'john.doe@example.com')

      # Verify the result is our mocked user
      expect(user).to eq(new_user)
    end
  end

  describe 'entity type and id' do
    it 'can use a proc for dynamic entity type' do
      # Create a class with dynamic entity type
      class DynamicEntityUser
        include PiiTokenizer::Tokenizable

        attr_accessor :role, :id

        tokenize_pii fields: { first_name: PiiTokenizer::PiiTypes::NAME },
                     entity_type: ->(user) { user.role || 'default' },
                     entity_id: ->(user) { "user_#{user.id}" }

        def initialize(id:, role:)
          @id = id
          @role = role
        end
      end

      user = DynamicEntityUser.new(id: 1, role: 'admin')
      expect(user.entity_type).to eq('admin')

      user.role = 'customer'
      expect(user.entity_type).to eq('customer')

      user.role = nil
      expect(user.entity_type).to eq('default')
    end

    it 'can use a string for static entity type' do
      # Create a class with static entity type
      class StaticEntityUser
        include PiiTokenizer::Tokenizable

        attr_accessor :id

        tokenize_pii fields: { first_name: PiiTokenizer::PiiTypes::NAME },
                     entity_type: PiiTokenizer::EntityTypes::USER_UUID,
                     entity_id: ->(user) { "user_#{user.id}" }

        def initialize(id:)
          @id = id
        end
      end

      user = StaticEntityUser.new(id: 1)
      expect(user.entity_type).to eq('USER_UUID')
    end
  end

  describe 'dual write mode' do
    it 'clears original fields when dual_write is false' do
      # Reset any mocks from previous tests
      RSpec::Mocks.space.reset_all

      # Save the original setting
      original_dual_write = User.dual_write_enabled

      # Set dual_write to false
      User.dual_write_enabled = false

      # Create a mock for the encryption service
      encryption_service = instance_double(PiiTokenizer::EncryptionService)
      allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)

      # Setup the encryption service mock to return tokens for a batch
      allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end

      # For decryption in accessors
      allow(encryption_service).to receive(:decrypt_batch) do |tokens|
        result = {}
        tokens = [tokens] unless tokens.is_a?(Array)
        tokens.each do |token|
          if token.to_s.start_with?('token_for_')
            original_value = token.to_s.sub('token_for_', '')
            result[token] = original_value
          end
        end
        result
      end

      # Track the SQL operations
      sql_operations = []
      allow(User.connection).to receive(:execute) do |sql|
        sql_operations << sql
        User.connection.__getobj__.execute(sql)
      end

      # Create a test user
      user = User.create!(first_name: 'John')

      # Extract the ID for verification
      user_id = user.id

      # Force a reload to ensure we're getting DB values
      user.reload

      # Check for direct SQL operations that show fields are cleared
      insert_sql = sql_operations.find { |sql| sql.include?('INSERT') }

      # Verify token column has value
      expect(user.first_name_token).to eq('token_for_John')

      # Original column should be nil in the database
      # We'll verify by checking what's actually stored
      expect(user.read_attribute(:first_name)).to be_nil

      # But accessor should still return the value via decryption
      expect(user.first_name).to eq('John')

      # Restore the original setting
      User.dual_write_enabled = original_dual_write
    end

    it 'keeps original fields when dual_write is true' do
      user = User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john@example.com')

      # Save dual_write setting before test and restore after
      original_dual_write = User.dual_write_enabled

      # Set dual_write to true
      User.dual_write_enabled = true

      # Set up encryption response with the actual entity type from integration tests
      allow(encryption_service).to receive(:encrypt_batch).and_return({
                                                                        'USER_UUID:1:NAME:John' => 'encrypted_first_name',
                                                                        'USER_UUID:1:NAME:Doe' => 'encrypted_last_name',
                                                                        'USER_UUID:1:EMAIL:john@example.com' => 'encrypted_email'
                                                                      })

      # Make sure to use the actual entity type/id settings
      allow(user).to receive(:entity_type).and_return('user_uuid')
      allow(user).to receive(:entity_id).and_return('1')

      # Directly call encrypt_pii_fields to avoid save logic
      user.save!
      user.reload
      # Original field should not be nil
      expect(user.read_attribute(:first_name)).to eq('John')
      expect(user.read_attribute(:first_name_token)).to eq('encrypted_first_name')
      expect(user.read_attribute(:last_name)).to eq('Doe')
      expect(user.read_attribute(:last_name_token)).to eq('encrypted_last_name')
      expect(user.read_attribute(:email)).to eq('john@example.com')
      expect(user.read_attribute(:email_token)).to eq('encrypted_email')

      # Reset the dual_write setting
      User.dual_write_enabled = original_dual_write
    end
  end

  describe 'with real ActiveRecord instance' do
    before do
      User.delete_all
    end

    it 'integrates with ActiveRecord callbacks' do
      user = User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john@example.com')

      # Set up encryption response with the actual entity type from integration tests
      allow(encryption_service).to receive(:encrypt_batch).and_return({
                                                                        'USER_UUID:1:NAME:John' => 'encrypted_first_name',
                                                                        'USER_UUID:1:NAME:Doe' => 'encrypted_last_name',
                                                                        'USER_UUID:1:EMAIL:john@example.com' => 'encrypted_email'
                                                                      })

      # Make sure to use the actual entity type/id settings from integration tests
      allow(user).to receive(:entity_type).and_return('user_uuid')
      allow(user).to receive(:entity_id).and_return('1')

      # Verify the callback gets called during save
      expect(user).to receive(:encrypt_pii_fields).and_call_original

      # Save the record
      user.save
    end
  end
end
