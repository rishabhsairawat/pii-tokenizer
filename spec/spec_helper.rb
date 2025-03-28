require "bundler/setup"
require "pii_tokenizer"
require "active_record"

# Set up an in-memory database for testing
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Run each test in a transaction
  config.around(:each) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  # Configure the PiiTokenizer for testing
  config.before(:suite) do
    PiiTokenizer.configure do |config|
      config.encryption_service_url = "http://example.com/api"
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
    t.timestamps
  end

  create_table :internal_users, force: true do |t|
    t.string :first_name
    t.string :last_name
    t.string :role
    t.timestamps
  end
end

# Define test models
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: [:first_name, :last_name, :email],
               entity_type: 'customer',
               entity_id: ->(record) { "User_customer_#{record.id}" }
end

class InternalUser < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: [:first_name, :last_name],
               entity_type: 'internal_staff',
               entity_id: ->(record) { "InternalUser_#{record.id}_#{record.role}" }
end 