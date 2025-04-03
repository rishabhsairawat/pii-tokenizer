# PiiTokenizer

[![Ruby](https://img.shields.io/badge/ruby-2.5.0%2B-blue.svg)](https://www.ruby-lang.org/en/)
[![Rails](https://img.shields.io/badge/rails-4.2%2B-orange.svg)](https://rubyonrails.org/)

PiiTokenizer is a Ruby gem that provides seamless tokenization of Personally Identifiable Information (PII) in ActiveRecord models. It integrates with an external encryption service to replace sensitive data with tokens.

## Features

- Transparent tokenization of sensitive PII fields in ActiveRecord models
- Automatic encryption on save and decryption on access
- Batch operations for improved performance
- Flexible configuration of entity types and identifiers
- Support for dual-write mode (maintaining both original and tokenized values)
- Chainable query methods for preloading tokenized fields

## Installation

Add to your Gemfile:

```ruby
gem 'pii_tokenizer'
```

Then install:

```bash
bundle install
```

## Database Setup

For each field you want to tokenize, add a corresponding `_token` column to store the encrypted value. For example:

```ruby
class AddTokenColumnsToUsers < ActiveRecord::Migration[6.0]
  def change
    add_column :users, :first_name_token, :string
    add_column :users, :last_name_token, :string
    add_column :users, :email_token, :string
  end
end
```

## Configuration

Create an initializer file:

```ruby
# config/initializers/pii_tokenizer.rb
PiiTokenizer.configure do |config|
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL'] || 'https://your-encryption-service.example.com'
  config.batch_size = 20 # Maximum items per batch request
  config.logger = Rails.logger # Use Rails logger
  config.log_level = :info
end
```

## Usage

### Basic Usage

Include the module in your ActiveRecord model and configure tokenization:

```ruby
class User < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: [:first_name, :last_name, :email],
               entity_type: 'customer',
               entity_id: ->(user) { "user_#{user.id}" },
               dual_write: false,
               read_from_token: true
end
```

### Custom PII Types

You can specify custom PII types for each field:

```ruby
class User < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
                 first_name: 'NAME',
                 last_name: 'NAME',
                 email: 'EMAIL',
                 ssn: 'SSN'
               },
               entity_type: 'customer',
               entity_id: ->(user) { "user_#{user.id}" }
end
```

### Dynamic Entity Types

You can use a proc for dynamic entity types:

```ruby
class User < ApplicationRecord
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: [:first_name, :last_name, :email],
               entity_type: ->(user) { user.role || 'customer' },
               entity_id: ->(user) { "user_#{user.id}" }
end
```

### Automatic Tokenization

The gem automatically tokenizes fields on save:

```ruby
user = User.create(first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')
# Data is tokenized automatically
```

### Reading Tokenized Values

Reading data is also transparent:

```ruby
user = User.find(1)
puts user.first_name # Automatically decrypts the token
```

### Batch Operations

For improved performance with collections:

```ruby
users = User.where(active: true).include_decrypted_fields(:first_name, :last_name)
users.each do |user|
  # Accessing first_name and last_name will use pre-decrypted values from batch operation
  puts "#{user.first_name} #{user.last_name}"
end
```

### Manual Decryption

You can also manually decrypt fields:

```ruby
# Decrypt a single field
value = user.decrypt_field(:email)

# Decrypt multiple fields at once
values = user.decrypt_fields(:first_name, :last_name, :email)
puts values[:first_name]
```

## Options

### Dual Write Mode

When `dual_write` is `true`, both the original column and the token column will contain values. When `false` (default), only the token column will have values, and the original column will be `nil`.

### Read From Token

When `read_from_token` is `true` (default), values will be read from token columns if they exist. When `false`, values will always be read from original columns.

## External Encryption Service

This gem requires an external encryption service that provides the following API endpoints:

- `POST /api/v1/tokens/bulk` - For batch encryption
- `GET /api/v1/tokens/decrypt` - For batch decryption

The service should handle encryption and decryption of sensitive data, returning tokens that can be safely stored in the database.

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

This gem is available as open source under the terms of the [MIT License](LICENSE).

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