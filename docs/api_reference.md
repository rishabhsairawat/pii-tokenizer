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

#### `find_or_create_by(attributes, &block)`

Securely finds or creates a record with tokenized fields, ensuring PII is never stored in plaintext in the database.

For new records, this method:
1. Attempts to find a record using tokenized search
2. If not found, creates a new record:
   - Stores tokenized field values in memory
   - Creates the record without sensitive data
   - Once the record has an ID, tokenizes the in-memory values
   - Updates the database with only the tokenized values  

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `attributes` | Hash | Attributes to search by and use for creation if not found |
| `block` | Proc | Optional block for additional initialization |

**Returns:**

A found or newly created record

**Example:**

```ruby
# Find or create a user with this email
user = User.find_or_create_by(email: 'john@example.com', role: 'admin')

# The email can still be accessed normally
puts user.email  # => john@example.com

# But stored securely in the database as a token
```

### Instance Methods

#### `encrypt_pii_fields`

Encrypts all tokenized fields for the record. This is called automatically before saving a record.

**Example:**

```ruby
user = User.new(first_name: "John", last_name: "Doe", email: "john@example.com")
user.encrypt_pii_fields
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

#### `include_decrypted_fields(*fields)`

Efficiently decrypts specified fields for a collection of records in a single API call.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `fields` | Array | The tokenized fields to decrypt |

**Returns:**

An ActiveRecord::Relation that will decrypt the specified fields in batch when executed.

**Example:**

```ruby
# Instead of N+1 decryption calls
users = User.where(active: true)
users.each { |user| puts user.email }  # Makes one API call per record

# Batch decryption - makes a single API call for all records
users = User.where(active: true).include_decrypted_fields(:email, :first_name)
users.each { |user| puts user.email }  # No additional API calls
```

#### `preload_decrypted_fields(records, *fields)`

Preloads decrypted values for multiple records in a single API call.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `records` | Array | Records to decrypt fields for |
| `fields` | Array | The tokenized fields to decrypt |

**Example:**

```ruby
users = User.where(active: true).to_a
User.preload_decrypted_fields(users, :email, :first_name)
users.each { |user| puts user.email }  # No additional API calls
```

#### `save(*args, &block)`

Securely saves a record with tokenized fields, ensuring PII is never stored in plaintext in the database.

For new records, this method:
1. Stores tokenized field values in memory
2. Clears original fields if `dual_write` is `false`
3. Saves the record to get an ID
4. Uses the in-memory values to encrypt and tokenize the data
5. Updates the database with only the tokenized values

**Returns:**

Boolean indicating whether the save succeeded

**Example:**

```ruby
user = User.new(email: 'jane@example.com')
user.save  # Saves record and tokenizes email securely
# The email can still be accessed via user.email
# But in the database, only email_token is set
```

#### `save!(*args, &block)`

Same as `save` but raises an exception if the record is invalid.

**Returns:**

The record itself, if save succeeds

**Raises:**

`ActiveRecord::RecordNotSaved` if record is invalid

**Example:**

```ruby
user = User.new(email: 'jane@example.com')
user.save!  # Raises exception if validation fails
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

## Error Handling

PiiTokenizer includes comprehensive error handling for all API operations. Here's how to handle common error scenarios:

### Encryption Service Connection Errors

Methods like `encrypt_batch`, `decrypt_batch`, and `search_tokens` can raise errors when they can't connect to the encryption service:

```ruby
begin
  # Attempt to encrypt data
  user.save
rescue RuntimeError => e
  if e.message.include?('Failed to connect to encryption service')
    # Handle connection issues
    Rails.logger.error("Encryption service unavailable: #{e.message}")
    # Consider implementing a retry mechanism
    retry_count ||= 0
    retry_count += 1
    retry if retry_count < 3
  else
    # Handle other errors
    raise
  end
end
```

### API Response Errors

Errors can also occur if the encryption service returns an error response:

```ruby
begin
  tokens = PiiTokenizer.encryption_service.search_tokens('example@email.com')
rescue RuntimeError => e
  if e.message.include?('Encryption service error')
    status_code = e.message.match(/HTTP (\d+)/)&.[](1)
    
    case status_code
    when '400'
      # Handle bad request errors
    when '401', '403'
      # Handle authentication/authorization errors
    when '500', '502', '503'
      # Handle server errors, possibly with retries
    else
      # Handle other API errors
    end
  else
    # Handle other runtime errors
    raise
  end
end
```

### Implementing Resilience

For production systems, consider adding resilience patterns:

```ruby
# Retry mechanism for transient errors
def with_retries(max_attempts: 3, base_delay: 1)
  attempts = 0
  begin
    attempts += 1
    yield
  rescue RuntimeError => e
    if e.message.include?('Failed to connect') && attempts < max_attempts
      # Exponential backoff
      sleep(base_delay * (2 ** (attempts - 1)))
      retry
    else
      raise
    end
  end
end

# Using the retry mechanism
with_retries do
  user = User.find_or_create_by(email: 'example@email.com')
end
```

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