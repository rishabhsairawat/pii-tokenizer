# PII Tokenizer

A Ruby on Rails gem to tokenize (encrypt/decrypt) PII attributes in ActiveRecord models.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'pii_tokenizer'
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
  config.encryption_service_url = ENV['ENCRYPTION_SERVICE_URL']
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

The gem will automatically:
- Encrypt specified fields before saving to the database
- Decrypt fields when accessing them from the model
- Batch encrypt/decrypt to minimize API calls

## How It Works

1. When a model with tokenized fields is saved, the gem intercepts and encrypts all the specified fields in a single batch request.
2. When model attributes are accessed, the gem automatically decrypts the fields on demand.
3. Batch operations are used for both encryption and decryption to minimize API calls.
4. Authentication is based on IP whitelisting; no API key is required.

## Compatibility

- Supports Ruby 2.4.1 or higher
- Compatible with Rails 4.2 and Rails 5.x

## Local Development

### Prerequisites

- Ruby 2.4.1 or higher
- Bundler
- SQLite3 (for running tests)

### Setup

1. Clone the repository:
```bash
git clone https://github.com/yourusername/pii_tokenizer.git
cd pii_tokenizer
```

2. Install dependencies:
```bash
bundle install
```

3. Run the setup script:
```bash
bin/setup
```

### Running Tests

Run the test suite:
```bash
bundle exec rspec
```

### Interactive Console

Start an interactive console for experimenting with the gem:
```bash
bin/console
```

### Building the Gem

Build the gem locally:
```bash
bundle exec rake build
```

### Running Tests with Different Ruby Versions

The gem supports Rails 4.2, Rails 5.x, and Ruby 2.4.1 or higher. To test against different Ruby versions, you can use rbenv or rvm:

```bash
# Using rbenv
rbenv install 2.4.1
rbenv local 2.4.1
bundle install
bundle exec rspec

# Using rvm
rvm install 2.4.1
rvm use 2.4.1
bundle install
bundle exec rspec
```

### Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT). 