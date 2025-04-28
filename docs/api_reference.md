# API Reference

This document provides a comprehensive reference for the PiiTokenizer gem's API.

## Table of Contents

- [Configuration](#configuration)
- [Tokenizable Module](#tokenizable-module)
  - [Class Methods](#class-methods)
  - [Instance Methods](#instance-methods)
- [EncryptionService](#encryptionservice)
- [Generators](#generators)
- [Version Compatibility](#version-compatibility)

## Configuration

### PiiTokenizer.configure

Configures the gem with global settings.

**Example:**

```ruby
PiiTokenizer.configure do |config|
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL']
  config.batch_size = 100
  config.logger = Rails.logger
  config.log_level = :info
end
```

**Parameters:**

| Option | Type | Description | Default |
|--------|------|-------------|---------|
| `encryption_service_url` | String | URL of the external encryption service | Required |
| `batch_size` | Integer | Default number of records to process in a batch | 100 |
| `logger` | Logger | Logger instance for logging operations | `Logger.new(STDOUT)` |
| `log_level` | Symbol | Log level for the logger | `:info` |

## Tokenizable Module

The `PiiTokenizer::Tokenizable` module is the main interface for tokenizing PII data. Include it in your ActiveRecord models to enable tokenization.

### Class Methods

#### `tokenize_pii(options)`

Configures tokenization for the model.

**Parameters:**

| Option | Type | Description | Default |
|--------|------|-------------|---------|
| `fields` | Hash or Array | Fields to tokenize with their PII types, or array of field names | Required |
| `entity_type` | String or Proc | The entity type for encryption | Required |
| `entity_id` | Proc | Method or proc that returns the entity ID | Required |
| `dual_write` | Boolean | Whether to write to both original and token columns | `false` |
| `read_from_token` | Boolean | Whether to read from token columns | Opposite of `dual_write` |

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

# Using an array of fields (will use field name uppercase as the PII type)
class Profile < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: [:first_name, :last_name, :email],
              entity_type: 'PROFILE',
              entity_id: ->(record) { record.id.to_s }
end
```

#### `tokenized_fields`

Returns an array of the fields configured for tokenization.

**Example:**

```ruby
User.tokenized_fields
# => [:first_name, :last_name, :email]
```

#### `token_column_for(field)`

Returns the name of the token column for a given field.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `field` | Symbol | The field name |

**Returns:**

The token column name as a string.

**Example:**

```ruby
User.token_column_for(:email)
# => "email_token"
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

#### `field_changed?(field)`

Checks if a tokenized field has changed, with Rails version-independent behavior.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `field` | Symbol | The field to check for changes |

**Returns:**

Boolean indicating whether the field has changed.

**Example:**

```ruby
user.first_name = "Jane"
user.field_changed?(:first_name)  # => true
```

## EncryptionService

The `PiiTokenizer::EncryptionService` class handles communication with the external encryption service.

### Methods

#### `encrypt_batch(tokens_data)`

Encrypts multiple values in a batch.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `tokens_data` | Array | Array of hashes with values to encrypt |

Each hash in the array should have these keys:
- `:value` - The value to encrypt
- `:entity_id` - The entity ID for this value
- `:entity_type` - The entity type
- `:field_name` - Name of the field being encrypted
- `:pii_type` - Type of PII data (e.g., EMAIL, PHONE)

**Returns:**

Hash mapping request keys to encrypted token values.

**Example:**

```ruby
tokens_data = [
  {value: 'John Smith', entity_id: 'user_1', entity_type: 'user_uuid', field_name: 'name', pii_type: 'NAME'},
  {value: 'john@example.com', entity_id: 'user_1', entity_type: 'user_uuid', field_name: 'email', pii_type: 'EMAIL'}
]
result = service.encrypt_batch(tokens_data)
```

#### `decrypt_batch(tokens_data)`

Decrypts multiple tokens in a batch.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `tokens_data` | Array or String | Tokens to decrypt |

Can be:
- A single token string
- An array of token strings
- An array of hashes with `:token`, `:entity_id`, `:entity_type`, and `:pii_type` keys

**Returns:**

Hash mapping tokens to decrypted values.

**Example:**

```ruby
tokens = ['encrypted_token_1', 'encrypted_token_2']
result = service.decrypt_batch(tokens)
```

#### `search_tokens(pii_value)`

Searches for tokens matching a specific PII value.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `pii_value` | String | The PII value to search for |

**Returns:**

Array of matching token values.

**Example:**

```ruby
tokens = service.search_tokens('john.doe@example.com')
```

## Generators

### `pii_tokenizer:token_columns`

Generates a migration to add token columns for specified fields.

**Usage:**

```bash
rails generate pii_tokenizer:token_columns MODEL_NAME FIELD1 FIELD2 ...
```

**Example:**

```bash
rails generate pii_tokenizer:token_columns user first_name last_name email
```

This generates a migration file with:

```ruby
add_column :users, :first_name_token, :string
add_column :users, :last_name_token, :string
add_column :users, :email_token, :string
```

## Version Compatibility

PiiTokenizer provides special handling for different Rails versions. See the [Rails Compatibility](rails_compatibility.md) document for details.

### Key Compatibility Methods

#### `rails5_or_newer?`

Checks if the Rails version is 5.0 or newer.

**Returns:**

Boolean indicating whether the Rails version is 5.0 or newer.

**Example:**

```ruby
if rails5_or_newer?
  # Code for Rails 5+ behavior
else
  # Code for Rails 4.x behavior
end
```

#### `rails4_2?`

Checks if the Rails version is 4.2.

**Returns:**

Boolean indicating whether the Rails version is 4.2.

**Example:**

```ruby
if rails4_2?
  # Rails 4.2 specific code
end
```

#### `active_record_version`

Returns the ActiveRecord version as a string.

**Returns:**

The ActiveRecord version as a string (e.g., "5.2").

**Example:**

```ruby
version = active_record_version
# => "5.2"
```

#### `safe_write_attribute(attribute, value)`

Safely writes an attribute value in a Rails version-independent way.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `attribute` | Symbol | The attribute to set |
| `value` | Object | The value to set |

**Returns:**

The value that was set.

**Example:**

```ruby
safe_write_attribute(:email_token, "encrypted_value")
``` 