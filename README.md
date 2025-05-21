# PiiTokenizer

[![Ruby](https://img.shields.io/badge/ruby-2.4.0%2B-blue.svg)](https://www.ruby-lang.org/en/)
[![Rails](https://img.shields.io/badge/rails-4.2%2B-orange.svg)](https://rubyonrails.org/)

PiiTokenizer is a Ruby gem that provides seamless tokenization of Personally Identifiable Information (PII) in ActiveRecord models. It integrates with an external encryption service to replace sensitive data with tokens, ensuring that PII data is never stored in plaintext in your database.

## Documentation

- [Getting Started Guide](docs/getting_started.md) - Step-by-step guide to set up and configure PiiTokenizer
- [API Reference](docs/api_reference.md) - Detailed information on all methods and options
- [Best Practices](docs/best_practices.md) - Recommendations for secure implementations
- [Data Migration Guide](docs/data_migration_guide.md) - Guide for migrating existing data to tokenized storage
- [JSON Field Tokenization](docs/JSON_FIELD_TOKENIZATION.md) - Guide for tokenizing specific keys within JSON columns
- [Troubleshooting](docs/troubleshooting.md) - Solutions for common issues
- [Rails Compatibility](docs/rails_compatibility.md) - Details on Rails version compatibility features
- [Testing Guide](TESTING.md) - Instructions for testing across different Rails versions

## Features

- **Transparent tokenization**: Replace sensitive PII with tokens in your database automatically
- **Seamless integration**: Works with existing ActiveRecord models with minimal configuration
- **Automatic handling**: Encrypt on save, decrypt on access—no manual intervention needed
- **Batch operations**: Efficient API calls for improved performance with collections
- **Secure handling**: PII is never stored in plaintext in your database
- **Optimized transactions**: Single-phase tokenization with no redundant database operations
- **Dual-write support**: Option to maintain both original and tokenized values
- **JSON field tokenization**: Tokenize specific keys within JSON columns while preserving structure
- **Flexible configuration**: Customize entity types, identifiers, and storage modes
- **Search capabilities**: Standard ActiveRecord query methods work with tokenized fields
- **Rails version support**: Full compatibility with Rails 4.2+ through 6.x

## Requirements

- **Ruby 2.4+** and **Rails 4.2+**
- Each tokenized field must have a corresponding `_token` column in your database
- A reliable entity identifier that is **always available** during model saves

## Entity ID Requirement

The PII Tokenizer requires a unique entity identifier for each record. This identifier is used to generate unique tokens for your data and must be available during the tokenization process.

**Important:** The entity_id proc must always return a valid value during model saves, even for new records. If your entity_id depends on a database-generated ID, ensure you're using a strategy that makes the ID available during the initial save operation.

Example of a reliable entity_id:
```ruby
# Using UUID that's set before save
tokenize_pii fields: {email: PiiTokenizer::PiiTypes::EMAIL},
           entity_type: PiiTokenizer::EntityTypes::USER_UUID,
           entity_id: ->(user) { user.uuid }

# Using an external ID that's guaranteed to be present
tokenize_pii fields: {email: PiiTokenizer::PiiTypes::EMAIL},
           entity_type: PiiTokenizer::EntityTypes::PROFILE_UUID,
           entity_id: ->(customer) { "customer_#{customer.external_id}" }
```

## Rails Version Compatibility

PiiTokenizer is fully compatible with Rails 4.2+ and newer versions. The gem includes specialized handling for version-specific differences:

- **ActiveRecord Changes Tracking**: 
  - In Rails 5+, `previous_changes` contains changes after a save operation
  - In Rails 4, `changes` contains these changes
  
- **Method Visibility Differences**:
  - Some methods like `write_attribute` have different visibility (private/public) across versions
  - PiiTokenizer uses `safe_write_attribute` to handle these differences

You don't need to worry about these differences - PiiTokenizer handles them transparently with internal compatibility layers. Your code will work the same way across all supported Rails versions.

### Testing Rails Compatibility

To verify the gem's compatibility with different Rails versions, run:

```bash
# Test against Rails 4.2
bundle exec rake rails4

# Test against Rails 5.2
bundle exec rake rails5

# Test against all supported Rails versions
bundle exec rake all_rails
```

For detailed testing instructions, see the [Testing Guide](TESTING.md).

## Quick Start

### Installation

Add to your Gemfile:

```ruby
gem 'pii_tokenizer'
```

Then install:

```bash
bundle install
```

Or install directly:

```bash
gem install pii_tokenizer
```

### Basic Configuration

Create an initializer to configure PiiTokenizer with your encryption service:

```ruby
# config/initializers/pii_tokenizer.rb
PiiTokenizer.configure do |config|
  # Required: URL of your encryption service
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL']
  
  # Optional: Default batch size for processing records (default: 100)
  config.batch_size = 100
  
  # Optional: Logger configuration
  config.logger = Rails.logger
  config.log_level = :info
end
```

### Setting Up Models

Include the module in your ActiveRecord model and configure tokenization:

```ruby
class User < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
                 first_name: PiiTokenizer::PiiTypes::NAME,
                 last_name: PiiTokenizer::PiiTypes::NAME,
                 email: PiiTokenizer::PiiTypes::EMAIL
               },
               entity_type: PiiTokenizer::EntityTypes::USER_UUID,
               entity_id: ->(user) { user.id.to_s },  # Must always return a valid value
               dual_write: false  # Optional: Set to true to keep original values alongside tokens
end
```

### Add Token Columns

Generate and run a migration to add the necessary token columns:

```bash
$ rails generate pii_tokenizer:token_columns user first_name last_name email
$ rails db:migrate
```

This will add columns named `first_name_token`, `last_name_token`, and `email_token`.

#### JSON Token Columns

For JSON field tokenization, you can use a specialized generator:

```bash
$ rails generate pii_tokenizer:json_token_columns profile profile_details user_settings
$ rails db:migrate
```

This will add `profile_details_token` and `user_settings_token` columns to the profiles table.

### Usage Example

```ruby
# Creating a new record
user = User.create(
  first_name: 'John',
  last_name: 'Doe',
  email: 'john.doe@example.com'
)

# Accessing tokenized fields (automatic decryption)
puts user.first_name  # "John"
puts user.email       # "john.doe@example.com"

# Batch decryption for better performance
user_data = user.decrypt_fields(:first_name, :last_name)
```

For more detailed setup and configuration options, please see the [Getting Started Guide](docs/getting_started.md).

## Advanced Usage

### Dynamic Entity Types

```ruby
class User < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
    first_name: PiiTokenizer::PiiTypes::NAME,
    last_name: PiiTokenizer::PiiTypes::NAME,
    email: PiiTokenizer::PiiTypes::EMAIL
  },
  entity_type: ->(user) { user.role == 'admin' ? PiiTokenizer::EntityTypes::USER_UUID : PiiTokenizer::EntityTypes::PROFILE_UUID },
  entity_id: ->(user) { "user_#{user.id}" }
end
```

### Batch Operations

```ruby
users = User.where(active: true).include_decrypted_fields(:first_name, :last_name)
users.each do |user|
  # Accessing first_name and last_name will use pre-decrypted values
  puts "#{user.first_name} #{user.last_name}"
end
```

### Manual Decryption

```ruby
# Decrypt a single field
value = user.decrypt_field(:email)

# Decrypt multiple fields at once
values = user.decrypt_fields(:first_name, :last_name, :email)
puts values[:first_name]
```

### Configuration Options

#### Dual Write Mode

When `dual_write` is `true`, both the original column and the token column will contain values. When `false` (default), only the token column will have values, and the original column will be `nil`.

```ruby
tokenize_pii fields: {email: PiiTokenizer::PiiTypes::EMAIL},
             entity_type: PiiTokenizer::EntityTypes::USER_UUID,
             entity_id: ->(user) { "user_#{user.id}" },
             dual_write: true  # Keep original values in database too
```

#### Read From Token Mode

By default, `read_from_token` is set to the opposite of `dual_write`:
- When `dual_write` is `false` (default), `read_from_token` defaults to `true`
- When `dual_write` is `true`, `read_from_token` defaults to `false`

You can explicitly set this value:

```ruby
tokenize_pii fields: {email: PiiTokenizer::PiiTypes::EMAIL},
             entity_type: PiiTokenizer::EntityTypes::USER_UUID,
             entity_id: ->(user) { "user_#{user.id}" },
             dual_write: true,
             read_from_token: true  # Use token columns for reading
```

When `read_from_token` is `true`:
- Values are read from token columns and decrypted
- Search methods (`find_by`, `where`) use token columns

When `read_from_token` is `false`:
- Values are read from original columns
- Search methods use original columns

See the [API Reference](docs/api_reference.md) for details on all configuration options.

### PII Type Validation

The gem enforces the use of predefined PII types from `PiiTokenizer::PiiTypes` to ensure consistency and correctness:

```ruby
# Using predefined PII types ensures consistency
class User < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
    first_name: PiiTokenizer::PiiTypes::NAME,
    last_name: PiiTokenizer::PiiTypes::NAME,
    email: PiiTokenizer::PiiTypes::EMAIL
  },
  entity_type: PiiTokenizer::EntityTypes::USER_UUID,
  entity_id: ->(user) { user.id.to_s }
end
```

Using undefined PII types will raise an `ArgumentError` with a list of all supported types.

## External Encryption Service API Contract

This gem requires an external encryption service that implements the following API endpoints:

### Encrypt Batch Endpoint

```
POST /api/v1/tokens/bulk
Content-Type: application/json

[
  {
    "entity_type": "string",  // Type of entity (e.g., "USER_UUID", "PROFILE_UUID")
    "entity_id": "string",    // Identifier for the entity (Actual Value for the entity id)
    "pii_type": "string",     // Type of PII (e.g., "EMAIL", "PHONE", "NAME")
    "pii_field": "string"     // The actual value to encrypt
  },
  ...
]

Response:
{
  "data": [
    {
      "entity_type": "string",
      "entity_id": "string",
      "pii_type": "string",
      "pii_field": "string",
      "token": "string"      // The generated token
    ...
    },
    ...
  ]
}
```

### Decrypt Batch Endpoint

```
GET /api/v1/tokens/decrypt?tokens[]=token1&tokens[]=token2
Accept: application/json

Response:
{
  "data": [
    {
      "token": "string",        // The original token
      "decrypted_value": "string"  // The decrypted value
    },
    ...
  ]
}
```

### Search Tokens Endpoint

```
POST /api/v1/tokens/search
Content-Type: application/json

{
  "pii_field": "string"  // The PII value to search for
}

Response:
{
  "data": [
    {
      "token": "string",       // The token that matched
      "decrypted_value": "string" // Original field sent in the request
    },
    ...
  ]
}
```

## Testing Your Application

When testing an application that uses PiiTokenizer, you'll want to avoid making real API calls:

```ruby
# In your test_helper.rb or spec_helper.rb
RSpec.configure do |config|
  config.before(:each) do
    # Create a mock encryption service
    mock_encryption_service = instance_double(PiiTokenizer::EncryptionService)
    
    # Set up mock behaviors for encrypt_batch
    allow(mock_encryption_service).to receive(:encrypt_batch) do |tokens_data|
      result = {}
      tokens_data.each do |token_data|
        key = "#{token_data[:entity_type]}:#{token_data[:entity_id]}:#{token_data[:pii_type]}"
        result[key] = "token_for_#{token_data[:value]}"
      end
      result
    end
    
    # Set up mock behaviors for decrypt_batch
    allow(mock_encryption_service).to receive(:decrypt_batch) do |tokens|
      result = {}
      tokens.each do |token|
        if token.to_s.start_with?('token_for_')
          result[token] = token.to_s.sub('token_for_', '')
        end
      end
      result
    end
    
    # Set up mock behaviors for search_tokens
    allow(mock_encryption_service).to receive(:search_tokens) do |value|
      ["token_for_#{value}"]
    end
    
    # Inject the mock into PiiTokenizer
    allow(PiiTokenizer).to receive(:encryption_service).and_return(mock_encryption_service)
  end
end
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Acknowledgments

- Built with ❤️ for secure data handling in Ruby on Rails applications

### Supported PII Types

PiiTokenizer provides a set of predefined PII types to ensure consistency:

```ruby
# Supported PII types
PiiTokenizer::PiiTypes::NAME     # For names (first, last, full)
PiiTokenizer::PiiTypes::EMAIL    # For email addresses
PiiTokenizer::PiiTypes::PHONE    # For phone numbers
PiiTokenizer::PiiTypes::URL      # For URLs and web addresses
```

### Supported Entity Types

PiiTokenizer provides predefined entity types:

```ruby
# Supported entity types
PiiTokenizer::EntityTypes::USER_UUID      # For user-related entities
PiiTokenizer::EntityTypes::PROFILE_UUID   # For profile-related entities
```
