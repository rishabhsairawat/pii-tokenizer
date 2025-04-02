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
class Customer < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
    first_name: 'NAME',
    last_name: 'NAME', 
    email: 'EMAIL',
    phone: 'PHONE'
  }, 
  entity_type: 'CUSTOMER',
  entity_id: ->(record) { "customer_#{record.id}" },
  dual_write: true,             # Write to both original and token columns
  read_from_token: false        # Read from original columns for now
end
```

### Accessing Tokenized Fields

Accessing tokenized fields is transparent - the gem handles decryption automatically:

```ruby
customer = Customer.find(1)
customer.first_name  # Automatically decrypts the value
customer.decrypt_fields(:first_name, :last_name)  # Batch decrypt multiple fields
```

### Batch Token Backfill

To tokenize existing data:

```bash
$ rake pii_tokenizer:backfill[Customer,1000]
```

This processes records in batches of 1000, tokenizing plaintext values and storing them in token columns.

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