require 'bundler/setup'
require 'simplecov'
require 'active_record'
require 'database_cleaner'

# Configure SimpleCov for test coverage reporting
if ENV['COVERAGE'] == 'true'
  SimpleCov.start do
    add_filter '/spec/'
    add_filter '/vendor/'

    add_group 'Core', 'lib/pii_tokenizer'
    add_group 'Libraries', 'lib'

    # Set a minimum coverage threshold
    minimum_coverage 60

    # Show coverage in console output
    formatter SimpleCov::Formatter::MultiFormatter.new([
                                                         SimpleCov::Formatter::HTMLFormatter
                                                       ])
  end

  puts 'SimpleCov enabled - generating coverage report'
end

require 'pii_tokenizer'
begin
  require 'pry'
rescue LoadError
  # Pry is optional for testing
end

begin
  require 'webmock/rspec'
  # Configure webmock to allow localhost connections for testing with a local encryption service
  WebMock.disable_net_connect!(allow_localhost: true)
rescue LoadError
  # Webmock is optional for testing
end

# Add a test implementation of callback methods
module CallbackMethods
  def before_save(method_name)
    define_method(:run_before_save) do
      send(method_name)
    end
  end

  def after_find(method_name)
    define_method(:run_after_find) do
      send(method_name)
    end
  end

  def after_initialize(method_name)
    define_method(:run_after_initialize) do
      send(method_name)
    end
  end
end

# Monkey patch Class to handle ActiveRecord callbacks in basic Ruby classes
class Class
  include CallbackMethods
end

# Set up an in-memory database for testing
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

# Mock Encryption Service Implementation
module MockEncryptionService
  # Mocks encrypt_batch to return predictable tokens based on input data
  def mock_encrypt_batch(tokens_data)
    result = {}
    # Ensure tokens_data is an array, default to empty if nil/unexpected type
    data_to_process = Array(tokens_data)
    data_to_process.each_with_index do |data, index|
      # Validate input data more carefully
      if data.is_a?(Hash) && data[:entity_type] && data[:entity_id] && data[:pii_type] && data[:field_name] && data.key?(:value)
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:field_name]}"
        result[key] = "mock_token_#{index}_for_[#{data[:value]}]_as_[#{data[:pii_type]}]"
      else
        puts "WARN: Invalid data format passed to mock_encrypt_batch: #{data.inspect}"
      end
    end
    # Always return a hash, even if processing failed or input was empty
    result
  end

  # Mocks decrypt_batch to reverse the mock token generation
  def mock_decrypt_batch(tokens)
    result = {}
    Array(tokens).each do |token|
      token_str = token.to_s
      # Attempt to parse the mock token format
      match = token_str.match(/^mock_token_\d+_for_\[(.*?)\]_as_\[(.*?)\]$/)
      if match
        original_value = match[1]
        # pii_type = match[2] # PII type is available if needed
        result[token_str] = original_value
      else
        # Handle edge cases or specific tokens needed by certain tests if the generic pattern doesn't match
        # Example:
        # case token_str
        # when 'specific_test_token'
        #   result[token_str] = 'specific_decrypted_value'
        # else
        #   puts "WARN: Mock decrypt could not parse token: #{token_str}"
        # end
      end
    end
    result
  end

  # Mocks search_tokens - returns a predictable token based on value for testing finders
  # Note: This assumes the token generated here would match one potentially stored.
  # Tests might need to mock this specifically if they depend on *exact* token values from a prior save.
  def mock_search_tokens(value)
    return [] if value.blank?
    # Generate a plausible token format that *might* exist in the DB for the value.
    # This is a simplification; real search might be more complex.
    ["mock_token_search_for_[#{value}]"]
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Use transactional fixtures for cleaner test runs
  # config.use_transactional_fixtures = true # Remove or comment out if using database_cleaner

  # Run each test in a transaction
  config.around do |example|
    begin
      example.run
    rescue StandardError => e
      puts "Test failed: #{e.message}"
      raise e
    end
  end

  # Configure the PiiTokenizer for testing
  config.before(:suite) do
    # Create a null logger to disable logging during tests
    null_logger = Logger.new(File.open(File::NULL, 'w'))
    null_logger.level = Logger::FATAL

    PiiTokenizer.configure do |config|
      config.encryption_service_url = 'http://localhost:8000'
      config.batch_size = 5
      config.logger = null_logger
      config.log_level = Logger::FATAL
    end

    # DatabaseCleaner configuration
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean_with(:truncation)
  end

  # Include the mock methods helpers into tests
  config.include MockEncryptionService

  # Setup mocks before each test
  config.before(:each) do
    # Create a fresh instance double for the service for each test
    mock_service = instance_double(PiiTokenizer::EncryptionService)

    # Stub the service methods to call our mock helpers
    allow(mock_service).to receive(:encrypt_batch) { |data| mock_encrypt_batch(data) }
    allow(mock_service).to receive(:decrypt_batch) { |tokens| mock_decrypt_batch(tokens) }
    allow(mock_service).to receive(:search_tokens) { |value| mock_search_tokens(value) }

    # Configure the PiiTokenizer to use our mocked service instance directly
    allow(PiiTokenizer).to receive(:encryption_service).and_return(mock_service)

    # Reset model configurations to defaults before each test
    [User, InternalUser, Contact].each do |model|
      # Assuming defaults are dual_write=false, read_from_token=true
      # Adjust if your actual defaults differ
      model.dual_write_enabled = false
      model.read_from_token_column = true
    end
  end

  config.around(:each) do |example|
    DatabaseCleaner.cleaning do
      example.run
    end
  end
end

# Create test tables
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :first_name
    t.string :last_name
    t.string :email

    # Add token columns
    t.string :first_name_token
    t.string :last_name_token
    t.string :email_token
  end

  create_table :internal_users, force: true do |t|
    t.string :first_name
    t.string :last_name
    t.string :role

    # Add token columns
    t.string :first_name_token
    t.string :last_name_token
  end

  create_table :contacts, force: true do |t|
    t.string :full_name
    t.string :phone_number
    t.string :email_address

    # Add token columns
    t.string :full_name_token
    t.string :phone_number_token
    t.string :email_address_token
  end
end

# Define test models
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  tokenize_pii fields: {
    first_name: 'FIRST_NAME',
    last_name: 'LAST_NAME',
    email: 'EMAIL'
  },
               entity_type: 'customer',
               entity_id: ->(record) { "User_customer_#{record.id}" },
               dual_write: false,
               read_from_token: true
end

class InternalUser < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  tokenize_pii fields: %i[first_name last_name],
               entity_type: 'internal_staff',
               entity_id: ->(record) { "InternalUser_#{record.id}_#{record.role}" },
               dual_write: false,
               read_from_token: true
end

class Contact < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  tokenize_pii fields: {
    full_name: 'NAME',
    phone_number: 'PHONE',
    email_address: 'EMAIL'
  },
               entity_type: 'contact',
               entity_id: ->(record) { "Contact_#{record.id}" },
               dual_write: false,
               read_from_token: true
end
