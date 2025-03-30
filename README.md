# PII Tokenizer

A Ruby on Rails gem to tokenize (encrypt/decrypt) PII attributes in ActiveRecord models.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'pii_tokenizer'
```

Or if you're using it from a local path:

```ruby
gem 'pii_tokenizer', path: '/path/to/pii_tokenizer'
```

Or from a git repository:

```ruby
gem 'pii_tokenizer', git: 'https://github.com/rishabhsairawat/pii_tokenizer.git'
```

And then execute:

```bash
$ bundle install
```

## Configuration

You need to configure the encryption service in an initializer:

```ruby
# config/initializers/pii_tokenizer.rb
PiiTokenizer.configure do |config|
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL'] # Base URL to your tokenization service
  config.batch_size = 20 # Maximum number of fields to encrypt/decrypt in a single API call
end
```

## Usage

Add the `tokenize_pii` method to your ActiveRecord models:

```ruby
class User < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: [:first_name, :last_name, :email],
               entity_type: 'customer', 
               entity_id: ->(record) { "User_customer_#{record.id}" }
end

class InternalUser < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: [:first_name, :last_name],
               entity_type: 'internal_staff',
               entity_id: ->(record) { "InternalUser_#{record.id}_#{record.role}" }
end
```

When you specify fields as an array like above, the gem will automatically use the uppercase field name as the `pii_type` when communicating with the tokenization service.

### Custom PII Types

You can specify custom PII types for each field instead of using the default uppercase field name:

```ruby
class Contact < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
                 full_name: 'NAME',
                 phone_number: 'PHONE',
                 email_address: 'EMAIL'
               },
               entity_type: 'contact',
               entity_id: ->(record) { "Contact_#{record.id}" }
end
```

This allows you to explicitly define how each field should be categorized in the tokenization service. You might want to do this when:

- You need to group different fields under the same PII type (e.g., first_name and last_name both as 'NAME')
- Your field names don't match the expected PII types in your tokenization service
- You need to follow specific naming conventions required by your tokenization service

### Usage in Code

Once configured, usage is transparent:

```ruby
# Creating a new record
user = User.create(first_name: "John", last_name: "Doe", email: "john@example.com")
# => The fields will be encrypted before saving to the database

# Reading a record
user = User.find(1)
user.first_name  # => Automatically decrypted
user.last_name   # => Automatically decrypted

# Updating a record
user.email = "new_email@example.com"
user.save  # => The email field will be encrypted before saving
```

The gem will automatically:
- Encrypt specified fields before saving to the database
- Decrypt fields when accessing them from the model
- Batch encrypt/decrypt to minimize API calls

## How It Works

1. When a model with tokenized fields is saved, the gem intercepts and encrypts all the specified fields in a single batch request.
2. When model attributes are accessed, the gem automatically decrypts the fields on demand.
3. Batch operations are used for both encryption and decryption to minimize API calls.
4. The gem maintains a cache of decrypted values to avoid redundant API calls.

## API Integration

The gem interacts with an external tokenization service that provides two main endpoints:

### Encryption Endpoint

```
POST /api/v1/tokens/bulk
```

Request Body:
```json
[
  {
    "entity_type": "customer",
    "entity_id": "User_123",
    "pii_type": "EMAIL",
    "pii_field": "user@example.com"
  }
]
```

Response:
```json
{
  "data": [
    {
      "token": "01JQGWZA3W1V7ZBZJ9DESH50T3",
      "entity_type": "CUSTOMER",
      "entity_id": "User_123",
      "pii_type": "EMAIL",
      "created_at": "2025-03-29T12:10:37.581+00:00"
    }
  ]
}
```

### Decryption Endpoint

```
GET /api/v1/tokens/decrypt?tokens=01JQGWZA3W1V7ZBZJ9DESH50T3
```

Response:
```json
{
  "data": [
    {
      "token": "01JQGWZA3W1V7ZBZJ9DESH50T3",
      "decrypted_value": "user@example.com"
    }
  ]
}
```

### Internal Key Format

When mapping between your ActiveRecord attributes and tokenized values, the gem uses a key format:

```
ENTITY_TYPE:entity_id:PII_TYPE
```

For example: `CUSTOMER:User_123:EMAIL`

Note that the `entity_type` is automatically uppercased in the key to match the response format from the tokenization service.

## Compatibility

- Supports Ruby 2.4.1 or higher
- Compatible with Rails 4.2 and Rails 5.x

## Dependencies

- Ruby >= 2.4.1
- ActiveRecord (>= 4.2, < 6.0)
- ActiveSupport (>= 4.2, < 6.0)
- Faraday (>= 0.17.3, < 2.0)

## Local Development

### Prerequisites

- Ruby 2.4.1 or higher
- Bundler (1.17.3 or 2.1.4)
- SQLite3 (for running tests)

### Setup

1. Clone the repository:
```bash
git clone https://github.com/rishabhsairawat/pii_tokenizer.git
cd pii_tokenizer
```

2. Install dependencies:
```bash
bundle install
```

3. Run the tests:
```bash
bundle exec rspec
```

4. Run the linter:
```bash
bundle exec rubocop
```


### Using in Another Application

To use the gem in development mode in another application:

1. Add to your application's Gemfile:
```ruby
gem 'pii_tokenizer', path: '/absolute/path/to/pii_tokenizer'
```

2. Install the gem:
```bash
bundle install
```

3. Create an initializer to configure the gem:
```ruby
# config/initializers/pii_tokenizer.rb
PiiTokenizer.configure do |config|
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL']
end
```

4. Use the gem in your models as shown in the Usage section.

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT). 