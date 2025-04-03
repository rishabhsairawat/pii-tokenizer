# PiiTokenizer

A Ruby gem for securely handling PII (Personally Identifiable Information) in ActiveRecord models using tokenization through an external encryption service. Built for applications that need to protect sensitive data while maintaining functionality.

[![Gem Version](https://badge.fury.io/rb/pii_tokenizer.svg)](https://badge.fury.io/rb/pii_tokenizer)

## Features

- **Field Tokenization**: Replace sensitive PII with secure tokens
- **Transparent Access**: Automatically decrypt data when accessed through model attributes
- **Dual-Write Strategy**: Support for gradual migration from plaintext to tokenized data 
- **Batch Processing**: Efficient token generation and decryption using batch operations
- **Custom PII Types**: Flexible configuration for different types of personally identifiable information
- **Rails Integration**: Generators for migrations, Rake tasks for data backfilling
- **Active Record Support**: Compatible with Rails 4.2+ through Rails 7

## Installation

Add the gem to your application's Gemfile:

```ruby
gem 'pii_tokenizer'
```

And install:

```
$ bundle install
```

## Quick Start

1. **Configure** the gem with your encryption service:

```ruby
# config/initializers/pii_tokenizer.rb
PiiTokenizer.configure do |config|
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL']
  config.batch_size = 100 # Optional, defaults to 100
end
```

2. **Set up your model** with tokenized fields:

```ruby
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
    first_name: 'FIRST_NAME',
    last_name: 'LAST_NAME', 
    email: 'EMAIL',
    ssn: 'SSN'
  }, 
  entity_type: 'USER',
  entity_id: ->(record) { record.id.to_s }
end
```

3. **Add token columns** to your database:

```bash
# Generate a migration to add token columns for specified fields
$ rails generate pii_tokenizer:token_columns user first_name last_name email ssn
$ rails db:migrate
```

This generates a migration that adds columns like `first_name_token`, `last_name_token`, etc.

4. **Add indices to token columns** (optional, but recommended for query performance):

```bash
# Generate a migration to add indices to the token columns
$ rails generate pii_tokenizer:token_indices user first_name last_name email ssn
$ rails db:migrate
```

The token indices generator creates optimized indices, including concurrent index creation for PostgreSQL.

## Migration Generators

### TokenColumns Generator

Creates a migration to add token columns to your database table:

```bash
$ rails generate pii_tokenizer:token_columns MODEL_NAME FIELD1 FIELD2 ...
```

For example, running:

```bash
$ rails generate pii_tokenizer:token_columns user first_name last_name email
```

Generates a migration like:

```ruby
class AddUserTokenColumns < ActiveRecord::Migration
  def change
    add_column :users, :first_name_token, :string
    add_column :users, :last_name_token, :string
    add_column :users, :email_token, :string
  end
end
```

### TokenIndices Generator

Creates a migration to add indices to your token columns:

```bash
$ rails generate pii_tokenizer:token_indices MODEL_NAME FIELD1 FIELD2 ...
```

For example, running:

```bash
$ rails generate pii_tokenizer:token_indices user first_name last_name email
```

Generates a migration with database-specific optimizations:

```ruby
class AddUserTokenIndices < ActiveRecord::Migration
  # Disable DDL transactions for PostgreSQL concurrent indexing
  disable_ddl_transaction!

  def change
    # Create indices concurrently on PostgreSQL, or normally on other databases
    if connection.adapter_name.downcase.include?('postgresql')
      add_index :users, :first_name_token, algorithm: :concurrently
      add_index :users, :last_name_token, algorithm: :concurrently
      add_index :users, :email_token, algorithm: :concurrently
    else
      add_index :users, :first_name_token
      add_index :users, :last_name_token
      add_index :users, :email_token
    end
  end
end
```

## Comprehensive Documentation

For detailed usage instructions, migration strategies, API documentation, and best practices:

- [**Getting Started**](docs/getting_started.md): Installation and basic setup
- [**API Reference**](docs/api_reference.md): Complete method documentation
- [**Data Migration Guide**](docs/data_migration_guide.md): Step-by-step migration from plaintext to tokenized data
- [**Best Practices**](docs/best_practices.md): Recommendations for secure tokenization
- [**Troubleshooting**](docs/troubleshooting.md): Common issues and solutions

## Data Migration Strategy

PiiTokenizer supports a gradual migration strategy through its dual-write capability:

1. **Phase 1: Setup** - Configure for dual-write but read from original columns
2. **Phase 2: Backfill** - Run the backfill task to populate token columns
3. **Phase 3: Switch Reading** - Change to reading from tokenized columns
4. **Phase 4: Clean Up** - Stop dual-write and eventually remove plaintext data

[See the detailed data migration guide](docs/data_migration_guide.md) for a complete walkthrough.

## Example Usage

### Basic Tokenization

```ruby
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
    first_name: 'NAME',
    last_name: 'NAME',
    email: 'EMAIL'
  },
  entity_type: 'USER',
  entity_id: ->(record) { record.id.to_s },
  dual_write: true,             # Write to both original and token columns
  read_from_token: false        # Read from original columns for now
end

# Creating a record
user = User.create(
  first_name: 'John', 
  last_name: 'Doe', 
  email: 'john.doe@example.com'
)

# Reading data (automatic decryption)
puts user.first_name  # => "John"
puts user.email       # => "john.doe@example.com"

# Batch decryption of multiple fields for a single record
data = user.decrypt_fields(:first_name, :last_name)
puts data[:first_name]  # => "John"
puts data[:last_name]   # => "Doe"
```

### Migration Approach

The dual-write and read-from-token options enable a safe, gradual migration:

```ruby
# Phase 1: Begin dual-write but still read from original columns
tokenize_pii dual_write: true, read_from_token: false

# Phase 2: After backfilling tokens, switch to reading from token columns
tokenize_pii dual_write: true, read_from_token: true

# Phase 3: Once confident in token data, stop writing to original columns
tokenize_pii dual_write: false, read_from_token: true
```

For more details, see the [Data Migration Guide](docs/data_migration_guide.md).

### Optimized Batch Processing

PiiTokenizer includes optimized batch processing to avoid N+1 API calls when working with collections:

```ruby
# Without optimization - causes N+1 API calls
users = User.where(active: true).limit(50)
users.each do |user|
  puts "#{user.first_name} #{user.last_name}"  # One API call per user
end

# With batch optimization - only one API call for all users
users = User.where(active: true)
  .include_decrypted_fields(:first_name, :last_name)
  .limit(50)
  
users.each do |user|
  puts "#{user.first_name} #{user.last_name}"  # No additional API calls
end

# For existing collections
users = User.where(created_at: 1.day.ago..Time.now).to_a
User.preload_decrypted_fields(users, :first_name, :last_name, :email)
```

## Configuration Options

| Option | Description |
|--------|-------------|
| `fields` | Hash mapping model fields to PII types or array of field names |
| `entity_type` | String or Proc returning the entity type identifier |
| `entity_id` | Proc returning a unique identifier for each record |
| `dual_write` | Whether to write to both original and token columns |
| `read_from_token` | Whether to read from token columns or original columns |

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Create a new Pull Request

## License

This gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Testing Your Application

When testing an application that uses PiiTokenizer, you'll want to avoid making real API calls to your encryption service. Here are strategies for effective testing:

### Mock the Encryption Service

```ruby
# In your test_helper.rb or spec_helper.rb
RSpec.configure do |config|
  config.before(:each) do
    # Create a mock encryption service
    mock_encryption_service = instance_double(PiiTokenizer::EncryptionService)
    
    # Set up mock behaviors for encrypt_batch
    allow(mock_encryption_service).to receive(:encrypt_batch) do |data|
      data.each_with_object({}) do |item, result|
        key = "#{item[:entity_type].upcase}:#{item[:entity_id]}:#{item[:pii_type]}"
        result[key] = "encrypted_#{item[:value]}"
      end
    end
    
    # Set up mock behaviors for decrypt_batch
    allow(mock_encryption_service).to receive(:decrypt_batch) do |tokens|
      tokens = [tokens] unless tokens.is_a?(Array)
      
      tokens.each_with_object({}) do |token, result|
        if token.start_with?("encrypted_")
          result[token] = token.sub("encrypted_", "")
        end
      end
    end
    
    # Inject the mock into PiiTokenizer
    allow(PiiTokenizer).to receive(:encryption_service).and_return(mock_encryption_service)
  end
end
```

### Test Batch Processing

When testing code that uses batch decryption, verify that it makes a single API call instead of multiple calls:

```ruby
it "decrypts multiple records in batch" do
  users = create_list(:user, 3)
  
  # Expect a single decrypt_batch call with all tokens
  expect(PiiTokenizer.encryption_service).to receive(:decrypt_batch)
    .once
    .with(array_including(users.map { |u| u.email_token }))
    .and_call_original
    
  # This should use batch decryption
  result = User.where(id: users.map(&:id))
              .include_decrypted_fields(:email)
              .map(&:email)
              
  expect(result.size).to eq(3)
end
```

### Testing with WebMock

If you prefer to test the actual HTTP requests, use WebMock to intercept API calls:

```ruby
# In your test_helper.rb or spec_helper.rb
require 'webmock/rspec'

RSpec.configure do |config|
  config.before(:each) do
    # Stub encrypt endpoint
    stub_request(:post, "#{ENV['ENCRYPTION_SERVICE_URL']}/api/v1/tokens/bulk")
      .to_return do |request|
        data = JSON.parse(request.body)
        response_data = data.map do |item|
          {
            token: "encrypted_#{item['pii_field']}",
            entity_type: item['entity_type'],
            entity_id: item['entity_id'],
            pii_type: item['pii_type']
          }
        end
        
        { 
          status: 200, 
          body: { data: response_data }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
      
    # Stub decrypt endpoint
    stub_request(:get, /#{ENV['ENCRYPTION_SERVICE_URL']}\/api\/v1\/tokens\/decrypt.*/)
      .to_return do |request|
        uri = Addressable::URI.parse(request.uri)
        tokens = uri.query_values['tokens'] || []
        tokens = [tokens] unless tokens.is_a?(Array)
        
        response_data = tokens.map do |token|
          {
            token: token,
            decrypted_value: token.sub('encrypted_', '')
          }
        end
        
        { 
          status: 200, 
          body: { data: response_data }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end
end
```

### Code Coverage

PiiTokenizer maintains high test coverage to ensure reliability. To run the test suite with code coverage reporting:

```bash
# Install dependencies
bundle install

# Run tests with coverage reporting
COVERAGE=true bundle exec rspec
```

After running the tests with coverage enabled, you'll find a detailed HTML report in the `coverage` directory. Open `coverage/index.html` in your browser to view:

- Overall code coverage percentage
- File-by-file coverage breakdown
- Line-by-line coverage visualization
- Missed lines not covered by tests

The code coverage threshold is set to 95% to ensure comprehensive test coverage. 