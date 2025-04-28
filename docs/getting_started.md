# Getting Started with PiiTokenizer

This guide will help you set up PiiTokenizer in your Rails application to securely handle personal information.

## Requirements

- Ruby 2.4.0 or higher
- Rails 4.2 or higher
- An external encryption service with a compatible API

## Installation

Add the gem to your application's Gemfile:

```ruby
gem 'pii_tokenizer'
```

And then install:

```bash
$ bundle install
```

## Basic Configuration

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

## Setting Up Models

### 1. Include the Tokenizable Module

Add the `PiiTokenizer::Tokenizable` module to your model:

```ruby
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  # Model code...
end
```

### 2. Configure Tokenized Fields

Define which fields should be tokenized, their PII types, and entity information:

```ruby
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
    first_name: 'NAME',
    last_name: 'NAME',
    email: 'EMAIL',
    ssn: 'SSN'
  },
  entity_type: 'USER',
  entity_id: ->(record) { record.id.to_s },
  dual_write: true  # Optional: Keeps original values alongside tokens
end
```

#### Configuration Options

- **fields**: Hash mapping model field names to PII types or an array of field names
- **entity_type**: String or Proc that defines the entity type for the record
- **entity_id**: Proc that returns a unique identifier for each record
- **dual_write**: (Optional) Whether to write to both original and token columns (default: false)
- **read_from_token**: (Optional) Whether to read from token columns (default: true when dual_write is false, false when dual_write is true)

### 3. Add Token Columns

Generate and run a migration to add the necessary token columns to your database:

```bash
$ rails generate pii_tokenizer:token_columns user first_name last_name email ssn
$ rails db:migrate
```

This will add columns named `first_name_token`, `last_name_token`, `email_token`, and `ssn_token`.

## Basic Usage

Once configured, you can use your model as usual. PiiTokenizer will handle encryption and decryption behind the scenes:

```ruby
# Creating a new record
user = User.create(
  first_name: 'John',
  last_name: 'Doe',
  email: 'john.doe@example.com',
  ssn: '123-45-6789'
)

# When saving, PiiTokenizer will encrypt sensitive fields
# and store tokens in the token columns

# Reading a record - automatic decryption
user = User.find(1)
puts user.first_name  # Transparently decrypts and returns "John"
puts user.email       # Transparently decrypts and returns "john.doe@example.com"
```

### Batch Decryption

You can decrypt multiple fields at once for better performance:

```ruby
# Decrypt multiple fields in one batch operation
user_data = user.decrypt_fields(:first_name, :last_name, :ssn)
puts user_data[:first_name]  # "John"
puts user_data[:last_name]   # "Doe"
puts user_data[:ssn]         # "123-45-6789"
```

## Security by Design

PiiTokenizer is built with security as a top priority:

- **No plaintext storage**: When `dual_write` is false (default), sensitive fields are kept in memory and only tokens are stored in the database
- **Secure record creation**: All `create`, `save`, and `find_or_create_by` operations safely handle PII data
- **Transparent access**: Access to fields works normally in your application code, while encryption/decryption happens behind the scenes
- **Batch processing**: Operations are optimized to reduce API calls and improve performance

Example of secure handling with `dual_write: false`:

```ruby
# Create a user with sensitive data
user = User.create(first_name: 'John', last_name: 'Doe', email: 'john@example.com')

# Access works as expected
puts "Hello, #{user.first_name}!"  # "Hello, John!"

# But in the database, only tokens are stored
# SELECT * FROM users WHERE id = 1;
# first_name: NULL, first_name_token: "encrypted_token"
```

## Migrating Existing Data

See the [Data Migration Guide](data_migration_guide.md) for a step-by-step process to migrate existing plaintext data to tokenized storage.

## Next Steps

- [Data Migration Guide](data_migration_guide.md): Learn how to migrate existing data to use tokenization
- [API Reference](api_reference.md): Detailed information on all methods and options
- [Best Practices](best_practices.md): Recommendations for secure implementations 