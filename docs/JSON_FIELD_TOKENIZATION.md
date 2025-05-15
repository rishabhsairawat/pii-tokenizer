# JSON Field Tokenization

This document explains how to use the JSON field tokenization feature of the PII Tokenizer gem.

## Overview

The JSON field tokenization feature allows you to tokenize specific keys within JSON columns in your database. This is particularly useful when you have PII data stored in JSON columns and want to protect that data without having to create separate columns for each piece of information.

## Requirements

Before using JSON field tokenization, you must:

1. Include `PiiTokenizer::Tokenizable` in your model
2. Call `tokenize_pii` to set up the entity_type and entity_id
3. Have at least one JSON column in your model
4. Create a corresponding "_token" column for each JSON column you want to tokenize
5. Define explicit PII types for each key you want to tokenize

### Database Setup

For each JSON column you want to tokenize, you need to create a corresponding "_token" column. You can do this manually with a migration:

```ruby
# Example migration
class AddTokenColumnsToProfiles < ActiveRecord::Migration[6.0]
  def change
    add_column :profiles, :profile_details_token, :json
  end
end
```

#### Using the Generator

Alternatively, you can use the included generator to create the migration for you:

```bash
# Generate a migration for JSON token columns
$ rails generate pii_tokenizer:json_token_columns profile profile_details user_details

# This will create a migration to add profile_details_token and user_details_token columns
```

The generator accepts the following options:

```bash
# Specify column type (defaults to json)
$ rails generate pii_tokenizer:json_token_columns profile profile_details --column_type=json
```

## Usage

```ruby
class Profile < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  # Configure regular tokenization with read_from_token_column option
  tokenize_pii fields: [:user_id], 
              entity_type: 'profile',
              entity_id: ->(profile) { "profile_#{profile.id}" },
              read_from_token_column: true  # Controls reading behavior for both regular and JSON fields
  
  # Configure JSON field tokenization
  tokenize_json_fields profile_details: {
    name: 'personal_name',
    email_id: 'email'
  }
end
```

## How It Works

### Database Storage

When you save a record with JSON field tokenization, the gem:

1. Extracts the values of the keys to be tokenized from the original JSON column
2. Tokenizes each value using the PiiTokenizer encryption service
3. Copies all non-tokenized fields from the original JSON to the token column
4. Stores the tokens in the corresponding "_token" column (e.g., profile_details_token)
5. The original JSON column remains unchanged

This approach allows you to gradually transition to using only the "_token" column, as it contains both tokenized PII and all other non-PII fields.

#### Example Storage

Original JSON column (profile_details):
```json
{
  "name": "John Doe",
  "email_id": "john@example.com",
  "listing_cap": 3
}
```

Token JSON column (profile_details_token):
```json
{
  "name": "ENCRYPTED_TOKEN_VALUE_1",
  "email_id": "ENCRYPTED_TOKEN_VALUE_2",
  "listing_cap": 3
}
```

### Accessing Tokenized Values

The gem provides several ways to access the decrypted values:

#### 1. Using the generated accessor methods

```ruby
profile = Profile.find(1)

# Access individual fields
name = profile.profile_details_name
email = profile.profile_details_email_id
```

#### 2. Using the original attribute accessor (with read_from_token_column: true)

```ruby
profile = Profile.find(1)

# When read_from_token_column: true is configured
profile_details = profile.profile_details
# Returns: { "name" => "John Doe", "email_id" => "john@example.com", "listing_cap" => 3 }
```

#### 3. Decrypting all keys at once

```ruby
profile = Profile.find(1)

# Get all decrypted values
decrypted_data = profile.decrypt_json_field(:profile_details)
name = decrypted_data['name']
email = decrypted_data['email_id']
listing_cap = decrypted_data['listing_cap'] # Non-tokenized field
```

Note that `decrypt_json_field` returns all fields, including both tokenized (with decrypted values) and non-tokenized fields from the token column.

## The `read_from_token_column` Option

The `read_from_token_column` option in your `tokenize_pii` configuration controls whether the model automatically reads from token columns for both regular and JSON fields:

```ruby
# With read_from_token_column: false (default)
profile.profile_details 
# Returns the original data from the profile_details column (with PII in plaintext)

# With read_from_token_column: true
profile.profile_details 
# Returns decrypted data from the token column (PII is decrypted automatically)
```

Setting `read_from_token_column: true` does the following for JSON fields:
1. Overrides the standard ActiveRecord attribute accessor to read from the token column
2. Automatically decrypts any tokenized values
3. Returns a hash with decrypted values for all tokenized fields
4. When token column is empty, it returns an empty hash (does not fall back to original data)

This is particularly useful when transitioning an application to use tokenized data without needing to change all the code that accesses the JSON field.

## Dual-Write Mode

The JSON field tokenization respects the `dual_write` setting from your `tokenize_pii` configuration, but it applies differently:

- When `dual_write: true`, the original JSON column remains untouched, while tokens are stored in the token column
- When `dual_write: false`, the original JSON column still remains untouched (no data is removed)

The main difference from regular field tokenization is that the original data always remains in the original JSON column.

## Migration Strategy

Since both tokenized and non-tokenized fields are stored in the "_token" column, you can eventually transition away from using the original column:

1. First deploy: Add the "_token" column, set up tokenization, run with dual_write true
2. Next deploy: Enable `read_from_token_column: true` to use the token column for reads
3. Final step: Eventually drop the original JSON column when it's no longer needed

## PII Types

Every key you want to tokenize **must** have an explicitly defined PII type. This ensures proper categorization of the sensitive data.

```ruby
# Directly map keys to their PII types
tokenize_json_fields profile_details: {
  name: 'personal_name',
  email_id: 'email',
  phone: 'telephone_number'
}
```

## Token Column Validation

The gem validates that the token columns required for JSON field tokenization exist in the database, but it handles this validation differently depending on the environment:

- In test environments: Validation happens immediately when the model is loaded
- In development/production: Validation is deferred until runtime (after model initialization)

This deferred validation allows you to:
1. Define your models with JSON tokenization before running migrations
2. Generate migrations for token columns
3. Run the migrations

Error messages will provide clear guidance if a token column is missing:
```
Column 'profile_details_token' must exist in the database for JSON field tokenization. Run a migration to add this column.
```

## Caching

Decrypted values are cached in memory during the request lifecycle, just like regular tokenized fields. This improves performance when accessing the same decrypted value multiple times.

## Limitations

- The JSON field tokenization does not support searching on tokenized JSON keys
- Only top-level keys in the JSON structure are supported for tokenization
- Nested JSON structures are not supported for tokenization
- Each JSON field to be tokenized must have a corresponding "_token" column

## Example Use Case

Imagine you have a profiles table with a JSON column containing PII data:

```ruby
# == Schema Information
#
# Table name: profiles
#  id                    :integer          not null, primary key
#  user_id               :integer          not null
#  profile_type          :string           not null
#  profile_details       :json
#  profile_details_token :json
#

class Profile < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  tokenize_pii fields: [:user_id],
              entity_type: 'profile',
              entity_id: ->(profile) { "profile_#{profile.id}" },
              pii_types: { user_id: 'id' },
              read_from_token_column: true  # Controls behavior for both regular and JSON fields
  
  # Direct mapping of keys to PII types
  tokenize_json_fields profile_details: {
    name: 'personal_name',
    email_id: 'email'
  }
end
```

Usage:

```ruby
# Creating a profile with PII in the JSON
profile = Profile.create!(
  user_id: 123,
  profile_type: 'customer',
  profile_details: {
    name: "John Doe",
    email_id: "john@example.com",
    listing_cap: 3
  }
)

# The values are automatically tokenized and stored in profile_details_token
# profile.profile_details_token now contains:
# {
#   "name": "ENCRYPTED_TOKEN_1",
#   "email_id": "ENCRYPTED_TOKEN_2",
#   "listing_cap": 3  # Note: non-tokenized fields are copied as-is
# }

# With read_from_token_column: true, you can access the decrypted data directly:
profile.profile_details
# Returns: {
#   "name": "John Doe",
#   "email_id": "john@example.com",
#   "listing_cap": 3
# }

# Individual field accessors still work the same:
name = profile.profile_details_name        # Returns "John Doe"
email = profile.profile_details_email_id   # Returns "john@example.com"

# Decrypting all fields at once (includes non-tokenized fields)
decrypted = profile.decrypt_json_field(:profile_details)
# decrypted = {
#   "name" => "John Doe",
#   "email_id" => "john@example.com",
#   "listing_cap" => 3
# }
``` 