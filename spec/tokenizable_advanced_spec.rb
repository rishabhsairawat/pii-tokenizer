require 'spec_helper'

RSpec.describe PiiTokenizer::Tokenizable do
  describe 'class methods' do
    it 'initializes class variables correctly' do
      # Reset the User class's tokenized fields
      # This is to ensure the test starts with a clean slate
      original_tokenized_fields = User.tokenized_fields.dup
      original_pii_types = User.pii_types.dup

      # Define a new temporary AR class
      temp_class = Class.new(ActiveRecord::Base) do
        self.table_name = 'users' # Use existing table for simplicity
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
    it 'handles find_or_initialize_by with tokenized fields' do
      # Mock search_tokens specifically for this test
      # Global mock is basic, we need it to return a specific format
      allow(PiiTokenizer.encryption_service).to receive(:search_tokens)
        .with('john.doe@example.com')
        .and_return(["mock_token_search_for_[john.doe@example.com]"]) # Match global mock's pattern

      # Call the method - This will now interact with the DB
      user = User.find_or_initialize_by(email: 'john.doe@example.com')

      # Verify the result - Check the object state
      expect(PiiTokenizer.encryption_service).to have_received(:search_tokens).with('john.doe@example.com').at_least(:once)
      expect(user).to be_a(User)
      expect(user).to be_new_record # Should not be persisted yet
      expect(user.email).to eq('john.doe@example.com')
    end

    it 'handles find_or_create_by with tokenized fields' do
      # Mock search_tokens specifically for this test
      allow(PiiTokenizer.encryption_service).to receive(:search_tokens)
        .with('jane.doe@example.com')
        .and_return([]) # Simulate not found

      # Call the method - This will create a record using AR and global mocks
      user = User.find_or_create_by(email: 'jane.doe@example.com')

      # Verify the result - Check DB state and object state
      expect(PiiTokenizer.encryption_service).to have_received(:search_tokens).with('jane.doe@example.com').at_least(:once)
      expect(user).to be_a(User)
      expect(user).to be_persisted
      expect(user.email).to eq('jane.doe@example.com')
      # Check that the global mock was used for encryption
      expect(user.email_token).to match(/^mock_token_\d+_for_\[jane\.doe@example\.com\]_as_\[EMAIL\]$/)
      # Verify record exists in DB
      expect(User.find(user.id)).to eq(user)
    end
  end

  describe 'entity type and id' do
    it 'can use a proc for dynamic entity type' do
      # Create a class with dynamic entity type inheriting from AR::Base
      class DynamicEntityUser < ActiveRecord::Base
        self.table_name = 'users' # Use existing table
        include PiiTokenizer::Tokenizable

        # No need for attr_accessor, AR handles columns
        # attr_accessor :role, :id

        tokenize_pii fields: [:first_name],
                     entity_type: ->(user) { user.role || 'default' },
                     entity_id: ->(user) { "user_#{user.id}" }

        # Need to define role attribute if not in schema
        attribute :role, :string

        # initialize is handled by AR
        # def initialize(id:, role:)
        #   @id = id
        #   @role = role
        # end
      end

      user = DynamicEntityUser.new(id: 1, role: 'admin')
      expect(user.entity_type).to eq('admin')

      user.role = 'customer'
      expect(user.entity_type).to eq('customer')

      user.role = nil
      expect(user.entity_type).to eq('default')
    end

    it 'can use a string for static entity type' do
      # Create a class with static entity type inheriting from AR::Base
      class StaticEntityUser < ActiveRecord::Base
        self.table_name = 'users' # Use existing table
        include PiiTokenizer::Tokenizable

        # No need for attr_accessor
        # attr_accessor :id

        tokenize_pii fields: [:first_name],
                     entity_type: 'static_type',
                     entity_id: ->(user) { "user_#{user.id}" }

        # initialize is handled by AR
        # def initialize(id:)
        #   @id = id
        # end
      end

      user = StaticEntityUser.new(id: 1)
      expect(user.entity_type).to eq('static_type')
    end
  end

  describe 'dual write mode' do
    it 'clears original fields when dual_write is false' do
      # Create a test user AFTER mock setup - Let AR handle this
      user = User.create!(first_name: 'John')

      # Extract the ID for verification
      user_id = user.id

      # Force a reload to ensure we're getting DB values
      user.reload

      # Verify token column has value (using global mock pattern)
      expect(user.first_name_token).to match(/^mock_token_\d+_for_\[John\]_as_\[FIRST_NAME\]$/)

      # Verify the original column is now NULL in DB
      # This relies on the AR create! and the after_save callback running correctly
      db_value = User.connection.select_value("SELECT first_name FROM users WHERE id = #{user.id}")
      expect(db_value).to be_nil
    end

    it 'keeps original fields when dual_write is true' do
      # Set dual_write to true for this test
      User.dual_write_enabled = true

      # Create user - Let AR handle save and callbacks
      user = User.create!(first_name: 'Jane')

      # Assertions
      # Verify global mock was called
      expect(PiiTokenizer.encryption_service).to have_received(:encrypt_batch).with(
        a_collection_containing_exactly(hash_including(value: 'Jane', field_name: 'first_name'))
      ).at_least(:once)

      # In dual write, original field should persist in DB
      user.reload # Ensure we read from DB
      expect(user.read_attribute(:first_name)).to eq('Jane') # Check attribute directly
      expect(user.first_name_token).to match(/^mock_token_\d+_for_\[Jane\]_as_\[FIRST_NAME\]$/) # Check token
    end
  end

  describe 'with real ActiveRecord instance' do
    before do
      # Ensure clean slate
      User.delete_all
    end

    it 'integrates with ActiveRecord callbacks' do
      # Use a real User instance connected to the test database
      # This will use the global mocks for encryption/decryption
      user = User.create!(first_name: 'John', last_name: 'Doe', email: 'john@example.com')

      # Expect the after_save callback to have triggered tokenization via the global mock
      expect(user.first_name_token).to match(/^mock_token_\d+_for_\[John\]_as_\[FIRST_NAME\]$/)
      expect(user.last_name_token).to match(/^mock_token_\d+_for_\[Doe\]_as_\[LAST_NAME\]$/)
      expect(user.email_token).to match(/^mock_token_\d+_for_\[john@example\.com\]_as_\[EMAIL\]$/)

      # Verify the global mock service was called
      expect(PiiTokenizer.encryption_service).to have_received(:encrypt_batch).at_least(:once)
    end
  end
end
