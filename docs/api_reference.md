# API Reference

This document provides a comprehensive reference for the PiiTokenizer gem's API.

## Table of Contents

- [Tokenizable Module](#tokenizable-module)
  - [Class Methods](#class-methods)
  - [Instance Methods](#instance-methods)
- [EncryptionService](#encryptionservice)
- [Generators](#generators)
- [Rake Tasks](#rake-tasks)

## Tokenizable Module

The `PiiTokenizer::Tokenizable` module is the main interface for tokenizing PII data. Include it in your ActiveRecord models to enable tokenization.

### Class Methods

#### `tokenize_pii(options)`

Configures tokenization for the model.

**Parameters:**

| Option | Type | Description | Default |
|--------|------|-------------|---------|
| `fields` | Hash | The fields to tokenize with their PII types | Required |
| `entity_type` | String | The entity type for encryption | Required |
| `entity_id` | Proc, Symbol | Method or proc that returns the entity ID | Required |
| `dual_write` | Boolean | Whether to write to both original and token columns | `false` |
| `read_from_token` | Boolean | Whether to read from token columns | `true` |

**Example:**

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
  dual_write: false,
  read_from_token: true
end
```

#### `tokenized_fields`

Returns an array of the fields configured for tokenization.

**Example:**

```ruby
User.tokenized_fields
# => [:first_name, :last_name, :email]
```

### Instance Methods

#### `encrypt_tokenized_fields`

Encrypts all tokenized fields for the record. This is called automatically before saving a record.

**Example:**

```ruby
user = User.new(first_name: "John", last_name: "Doe", email: "john@example.com")
user.encrypt_tokenized_fields
# Sets first_name_token, last_name_token, and email_token with encrypted values
```

#### `decrypt_field(field_name)`

Decrypts a specific tokenized field.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `field_name` | Symbol | The name of the field to decrypt |

**Returns:**

The decrypted value of the field, or the original value if decryption fails.

**Example:**

```ruby
user.decrypt_field(:email)
# => "john@example.com"
```

#### `decrypt_fields(*field_names)`

Decrypts multiple fields in a single batch request to the encryption service.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `field_names` | Array | The names of the fields to decrypt |

**Returns:**

A hash mapping field names to their decrypted values.

**Example:**

```ruby
user.decrypt_fields(:first_name, :last_name, :email)
# => { first_name: "John", last_name: "Doe", email: "john@example.com" }
```

#### `token_column_name(field_name)`

Returns the name of the token column for the given field.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `field_name` | Symbol | The original field name |

**Returns:**

The name of the corresponding token column.

**Example:**

```ruby
user.token_column_name(:first_name)
# => :first_name_token
```

## EncryptionService

The `PiiTokenizer::EncryptionService` handles communication with the external encryption service.

### Class Methods

#### `new(url)`

Creates a new EncryptionService instance.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `url` | String | The URL of the encryption service |

**Example:**

```ruby
service = PiiTokenizer::EncryptionService.new("https://encryption-service.example.com")
```

### Instance Methods

#### `encrypt_batch(data)`

Encrypts a batch of data.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | Array | Array of hashes with entity_type, entity_id, pii_type, and value |

**Returns:**

A hash mapping entity_type:entity_id:pii_type to encrypted tokens.

**Example:**

```ruby
service.encrypt_batch([
  { entity_type: 'USER', entity_id: '1', pii_type: 'EMAIL', value: 'john@example.com' },
  { entity_type: 'USER', entity_id: '1', pii_type: 'NAME', value: 'John' }
])
# => { 'USER:1:EMAIL' => 'encrypted_token_1', 'USER:1:NAME' => 'encrypted_token_2' }
```

#### `decrypt_batch(tokens)`

Decrypts a batch of tokens.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `tokens` | Array | Array of token strings to decrypt |

**Returns:**

A hash mapping token strings to their decrypted values.

**Example:**

```ruby
service.decrypt_batch(['encrypted_token_1', 'encrypted_token_2'])
# => { 'encrypted_token_1' => 'john@example.com', 'encrypted_token_2' => 'John' }
```

## Generators

PiiTokenizer provides generators to help with setting up token columns and indices.

### TokenColumnsGenerator

Generates a migration to add token columns for tokenized fields.

**Usage:**

```bash
rails generate pii_tokenizer:token_columns MODEL_NAME FIELD1 FIELD2 ...
```

**Example:**

```bash
rails generate pii_tokenizer:token_columns user first_name last_name email
```

### TokenIndicesGenerator

Generates a migration to add indices to token columns.

**Usage:**

```bash
rails generate pii_tokenizer:token_indices MODEL_NAME FIELD1 FIELD2 ...
```

**Example:**

```bash
rails generate pii_tokenizer:token_indices user first_name last_name email
```

## Rake Tasks

PiiTokenizer provides rake tasks for common operations.

### Backfill Task

Backfills token columns with encrypted values from original columns.

**Usage:**

```bash
rake pii_tokenizer:backfill[MODEL_NAME,BATCH_SIZE]
```

**Parameters:**

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `MODEL_NAME` | String | The name of the model class to backfill | Required |
| `BATCH_SIZE` | Integer | The number of records to process in each batch | 1000 |

**Example:**

```bash
rake pii_tokenizer:backfill[User,500]
```

## Configuration

PiiTokenizer can be configured with an initializer:

```ruby
# config/initializers/pii_tokenizer.rb
PiiTokenizer.configure do |config|
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL']
  config.batch_size = 100  # Default batch size for operations
  config.logger = Rails.logger
  config.log_level = :debug
end
```

**Configuration Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `encryption_service_url` | URL of the encryption service | Required |
| `batch_size` | Default batch size for operations | 100 |
| `logger` | Custom logger instance | `nil` (uses STDOUT) |
| `log_level` | Log level (:debug, :info, :warn, :error, :fatal) | `:info` |

## Logging

PiiTokenizer provides logging for all API calls to the encryption service:

```ruby
# config/initializers/pii_tokenizer.rb
PiiTokenizer.configure do |config|
  # Use Rails logger instead of default STDOUT logger
  config.logger = Rails.logger
  
  # Set to debug for more verbose output
  config.log_level = :debug
end
```

The logged information includes:
- Request method, URL, and sanitized payload (sensitive data is redacted)
- Response status code and sanitized response body
- Error details when requests fail 