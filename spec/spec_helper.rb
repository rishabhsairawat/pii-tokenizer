require 'bundler/setup'
require 'pii_tokenizer'
require 'active_record'
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

# Set up an in-memory database for testing
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

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
    PiiTokenizer.configure do |config|
      config.encryption_service_url = 'http://localhost:8000'
      config.batch_size = 5
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
