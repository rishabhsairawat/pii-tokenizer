require 'bundler/setup'
require 'simplecov'
require 'fileutils'
require 'logger'
require 'active_record'
require 'webmock/rspec'

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

# Create support directory if it doesn't exist
FileUtils.mkdir_p('spec/support') unless File.directory?('spec/support')

# Load Rails version compatibility patches first
require_relative 'support/bigdecimal_patch'

# Then load the actual code
require 'pii_tokenizer'

# Load database setup
require_relative 'support/database_setup'

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

# Define test models
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  # Helper for test compatibility with Rails 4 and 5
  def safe_write_attribute(attribute, value)
    if ::ActiveRecord::VERSION::MAJOR >= 5
      write_attribute(attribute, value)
    else
      # In Rails 4.2, write_attribute is private
      send(:write_attribute, attribute, value)
    end
  end

  tokenize_pii fields: {
    first_name: 'FIRST_NAME',
    last_name: 'LAST_NAME',
    email: 'EMAIL'
  },
               entity_type: 'user_uuid',
               entity_id: ->(record) { record.id.to_s },
               dual_write: false,
               read_from_token: true
end

class InternalUser < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  # Helper for test compatibility with Rails 4 and 5
  def safe_write_attribute(attribute, value)
    if ::ActiveRecord::VERSION::MAJOR >= 5
      write_attribute(attribute, value)
    else
      # In Rails 4.2, write_attribute is private
      send(:write_attribute, attribute, value)
    end
  end

  tokenize_pii fields: %i[first_name last_name],
               entity_type: 'internal_staff',
               entity_id: ->(record) { "InternalUser_#{record.id}_#{record.role}" },
               dual_write: false,
               read_from_token: true
end

class Contact < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  # Helper for test compatibility with Rails 4 and 5
  def safe_write_attribute(attribute, value)
    if ::ActiveRecord::VERSION::MAJOR >= 5
      write_attribute(attribute, value)
    else
      # In Rails 4.2, write_attribute is private
      send(:write_attribute, attribute, value)
    end
  end

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

# Load shared contexts - either the combined file OR individual files
if File.exist?('spec/support/shared_contexts.rb')
  # If shared_contexts.rb exists, use that instead of the other individual files
  require_relative 'support/shared_contexts'
else
  # Otherwise load the other individual shared context files
  require_relative 'support/shared_contexts/with_encryption_service'
  require_relative 'support/shared_contexts/with_tokenizable_models'
  require_relative 'support/shared_contexts/with_http_mocks'
end

# Always load the tokenization test helpers
require_relative 'support/shared_contexts/tokenization_test_helpers'

# Load any remaining support files
Dir['./spec/support/**/*.rb'].sort.each do |file|
  # Skip files we've already loaded
  next if file =~ /bigdecimal_patch\.rb/ ||
          file =~ /database_setup\.rb/ ||
          file =~ /shared_contexts\.rb/ ||
          file =~ %r{shared_contexts/}

  require file
end

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
    # Create a null logger to disable logging during tests
    null_logger = Logger.new(File.open(File::NULL, 'w'))
    null_logger.level = Logger::FATAL

    PiiTokenizer.configure do |config|
      config.encryption_service_url = 'http://localhost:8000'
      config.batch_size = 5
      config.logger = null_logger
      config.log_level = Logger::FATAL
    end
  end

  # Include the tokenization test helpers in all tests
  config.include_context 'tokenization test helpers'

  # Include other shared contexts with tags
  config.include_context 'with encryption service', :use_encryption_service
  config.include_context 'with tokenizable models', :use_tokenizable_models
  config.include_context 'with http mocks', :use_http_mocks
end
