# Troubleshooting Guide

This guide helps you diagnose and resolve common issues when working with PiiTokenizer.

## Table of Contents

- [Connection Issues](#connection-issues)
- [Tokenization Problems](#tokenization-problems)
- [Entity ID Issues](#entity-id-issues)
- [Search and Query Issues](#search-and-query-issues)
- [Performance Issues](#performance-issues)
- [Rails Version Compatibility](#rails-version-compatibility)
- [Debugging Tips](#debugging-tips)

## Common Issues and Solutions

### Missing Token Columns

**Symptoms:**
- Error: `undefined method 'first_name_token=' for #<User:0x00007f8>`
- Error: `PG::UndefinedColumn: ERROR: column users.first_name_token does not exist`

**Causes:**
- Migration to add token columns not created or run
- Migration created but contains errors

**Solutions:**
1. Verify that token columns exist in your database:
   ```ruby
   ActiveRecord::Base.connection.columns(:users).map(&:name)
   ```

2. Generate and run the token columns migration:
   ```bash
   rails generate pii_tokenizer:token_columns user first_name last_name email
   rails db:migrate
   ```

3. Check migration status:
   ```bash
   rails db:migrate:status
   ```

### Nil Values in Token Columns

**Symptoms:**
- Token columns are nil after saving records
- Decryption returns nil for fields that should have values

**Causes:**
- `encrypt_pii_fields` callback not running
- Encryption service returning errors
- `before_save` callback order issues

**Solutions:**
1. Verify that the model includes the Tokenizable module and has `tokenize_pii` configured:
   ```ruby
   User.ancestors.include?(PiiTokenizer::Tokenizable)
   User.respond_to?(:tokenized_fields)
   ```

2. Check the encryption service connection:
   ```ruby
   PiiTokenizer.encryption_service.encrypt_batch([
     { entity_type: 'TEST', entity_id: '1', pii_type: 'TEST', value: 'test' }
   ])
   ```

3. Add explicit callback to encrypt fields:
   ```ruby
   user = User.first
   user.first_name = "John"
   user.encrypt_pii_fields  # Call explicitly
   user.save
   ```

### Encryption Service Connection Issues

**Symptoms:**
- Timeouts when saving records
- Network-related errors

**Causes:**
- Incorrect encryption service URL
- Network connectivity issues
- Authentication failures

**Solutions:**
1. Verify the encryption service URL:
   ```ruby
   PiiTokenizer.encryption_service.instance_variable_get(:@url)
   ```

2. Check network connectivity:
   ```bash
   curl -v your-encryption-service-url/health-check
   ```

3. Review Rails logs for API call details:
   ```bash
   tail -f log/development.log | grep "EncryptionService"
   ```

4. Update the encryption service URL in your initializer:
   ```ruby
   # config/initializers/pii_tokenizer.rb
   PiiTokenizer.configure do |config|
     config.encryption_service_url = "https://new-url.example.com"
   end
   ```

### Decryption Returns Incorrect Values

**Symptoms:**
- Fields return encrypted tokens instead of decrypted values
- Decrypted values don't match original values

**Causes:**
- `read_from_token` configuration incorrect
- Decryption service issues
- Caching problems

**Solutions:**
1. Verify the `read_from_token` configuration:
   ```ruby
   # In your model
   tokenize_pii fields: {...},
     read_from_token: true  # Ensure this is set correctly
   ```

2. Clear any decryption caches:
   ```ruby
   user = User.find(1)
   user.instance_variable_set(:@decrypted_values, {})
   ```

3. Test decryption explicitly:
   ```ruby
   user = User.find(1)
   user.decrypt_field(:first_name)  # Does this return expected value?
   ```

### Performance Issues

**Symptoms:**
- Slow record creation/updates
- N+1 API calls during record access
- High API load on encryption service

**Causes:**
- Individual field decryption instead of batch
- Inefficient query patterns
- Small batch sizes

**Solutions:**
1. Use batch decryption for collections:
   ```ruby
   # Instead of:
   users.each { |user| puts user.first_name }
   
   # Use:
   user_ids = users.map(&:id)
   User.where(id: user_ids).include_decrypted_fields(:first_name)
   ```

2. Adjust batch size:
   ```ruby
   # config/initializers/pii_tokenizer.rb
   PiiTokenizer.configure do |config|
     config.batch_size = 200  # Adjust based on your needs
   end
   ```

3. Add caching for frequently accessed records:
   ```ruby
   # Simple caching mechanism
   def decrypted_first_name
     @cached_first_name ||= decrypt_field(:first_name)
   end
   ```

### Backfill Task Issues

**Symptoms:**
- Backfill task fails
- Some records not tokenized
- Inconsistent data state

**Causes:**
- Large record sets
- Invalid plaintext data
- Database connection issues

**Solutions:**
1. Run backfill with smaller batch size:
   ```bash
   rake pii_tokenizer:backfill[User,100]
   ```

2. Run backfill for specific record ranges:
   ```ruby
   # Custom backfill for a range
   User.where(id: 1000..2000).find_each do |user|
     # Skip if already tokenized
     next if user.first_name_token.present?
     
     user.encrypt_pii_fields
     user.save(validate: false)
   end
   ```

3. Monitor progress and resume from failures:
   ```bash
   # Note last successful ID
   last_id = User.where.not(first_name_token: nil).maximum(:id)
   
   # Resume from that point
   User.where("id > ?", last_id).find_each do |user|
     user.encrypt_pii_fields
     user.save(validate: false)
   end
   ```

### Rails Version Compatibility

**Symptoms:**
- Inconsistent behavior between Rails 4 and Rails 5 applications
- Error messages related to method visibility
- Issues with changes not being detected

**Possible causes:**
- Rails version incompatibility
- API changes between Rails versions
- Using version-specific methods directly
- Method visibility differences between Rails versions

**Solution:**
PiiTokenizer includes specialized handling for Rails version differences. We've created a dedicated [Rails Compatibility Guide](rails_compatibility.md) that provides comprehensive information on this topic. 

Key differences to be aware of:
- In Rails 4, `changes` contains the field changes after save
- In Rails 5+, `previous_changes` contains changes after save
- Method visibility differences (e.g., `write_attribute` is private in Rails 4.2)
- Special method implementations for Rails 4 compatibility

Use the version-agnostic helper methods provided by PiiTokenizer:

```ruby
# For Rails 4 & 5 compatibility with change tracking:
def field_changed?(field)
  field_str = field.to_s
  if rails5_or_newer?
    respond_to?(:previous_changes) && previous_changes.key?(field_str)
  else
    respond_to?(:changes) && changes.key?(field_str)
  end
end
```

To diagnose issues:

```ruby
# In Rails console, test change detection:
user = User.create(first_name: "John")
user.update(first_name: "Jane")

# Rails 4:
user.changes

# Rails 5+:
user.previous_changes

# Verify field_changed? works correctly:
user.field_changed?('first_name')  # Works in both Rails 4 and 5+
```

Use version-agnostic methods:
```ruby
# Instead of direct Rails version specific code:
if user.previous_changes.key?('first_name')  # Rails 5+ only

# Use the version-agnostic helper:
if user.active_changes.key?('first_name')    # Works in both Rails 4 and 5+
```

**Testing:**
1. Run the Rails 4.2 compatibility tests: `bundle exec rspec spec/rails4_compatibility_spec.rb`
2. Run all tests for your specific Rails version: `bundle exec rake rails4` or `bundle exec rake rails5`

For more details and advanced techniques for handling Rails version differences, refer to the [Rails Compatibility Guide](rails_compatibility.md).

## Debugging Techniques

### Logging

Enable detailed logging for debugging:

```ruby
# config/initializers/pii_tokenizer.rb
PiiTokenizer.configure do |config|
  config.debug = true  # If supported by the gem
end

# Or add custom logging
module PiiTokenizer
  class EncryptionService
    alias_method :original_encrypt_batch, :encrypt_batch
    
    def encrypt_batch(data)
      Rails.logger.debug "Encrypting: #{data.inspect}"
      result = original_encrypt_batch(data)
      Rails.logger.debug "Encryption result: #{result.inspect}"
      result
    end
  end
end
```

### Suppressing Logs During Tests

When running tests, you might want to suppress PiiTokenizer logs to keep your test output clean:

```ruby
# spec/spec_helper.rb or test/test_helper.rb
RSpec.configure do |config|
  config.before(:suite) do
    # Create a null logger that discards all output
    null_logger = Logger.new(File.open(File::NULL, 'w'))
    # Setting log level to FATAL will suppress most messages
    null_logger.level = Logger::FATAL

    # Configure PiiTokenizer to use the null logger
    PiiTokenizer.configure do |config|
      config.logger = null_logger
      config.log_level = Logger::FATAL
    end
  end
end
```

For individual test files that test error conditions, you might need to override the global logger:

```ruby
# In specific test files that test error handling
before do
  config = PiiTokenizer::Configuration.new
  config.encryption_service_url = 'https://test-service.example.com'
  # Add null logger to silence logs during specific tests
  config.logger = Logger.new(File.open(File::NULL, 'w'))
  config.log_level = Logger::FATAL
  @service = PiiTokenizer::EncryptionService.new(config)
end
```

### Console Testing

Use Rails console to test tokenization:

```ruby
# Start a console
rails c

# Test encryption
user = User.new(first_name: "Test", last_name: "User")
user.valid?  # Triggers callbacks
user.first_name_token  # Check if token was generated

# Test decryption
user.save
reloaded = User.find(user.id)
reloaded.first_name  # Should decrypt and return "Test"

# Check configuration
User.tokenized_fields  # Should return array of fields
```

### Environment Isolation

Test in isolated environments:

```ruby
# Create test user with tokenization
user = nil
ActiveRecord::Base.transaction do
  user = User.create(first_name: "Temp", last_name: "User")
  puts "Token: #{user.first_name_token}"
  puts "Decrypts to: #{user.first_name}"
  raise ActiveRecord::Rollback  # Prevent persistence
end
```

## Getting Support

If you continue to experience issues after trying these troubleshooting steps:

1. Check the [GitHub repository](https://github.com/yourusername/pii-tokenizer) for open issues
2. Review the [CHANGELOG](https://github.com/yourusername/pii-tokenizer/blob/master/CHANGELOG.md) for known issues in your version
3. Reach out to the maintainers with:
   - Ruby and Rails versions
   - PiiTokenizer version
   - Detailed error messages
   - Steps to reproduce the issue
   - Example code (sanitized of any sensitive data)

## Next Steps

- [Data Migration Guide](data_migration_guide.md): For migration-specific issues
- [API Reference](api_reference.md): For detailed method documentation
- [Best Practices](best_practices.md): For recommendations to avoid common issues 

## Entity ID Issues

### Missing or Invalid Entity ID

**Symptoms:**
- Token columns are empty or contain incorrect values
- Errors like "entity_id cannot be nil" or "entity_id is required"
- Tokenization works inconsistently across records

**Possible Causes:**
- The entity_id proc returns nil or an empty string
- The entity_id is not available during the save process (e.g., when using database-generated IDs for new records)
- Inconsistent entity_id values between save operations

**Solutions:**

1. **Ensure entity_id is always available:**
   ```ruby
   # BAD - may return nil for new records
   entity_id: ->(user) { user.id&.to_s }
   
   # GOOD - ensures entity_id is always available
   entity_id: ->(user) { 
     user.id.present? ? "user-#{user.id}" : "user-temp-#{SecureRandom.uuid}"
   }
   ```

2. **Use pre-assigned identifiers:**
   ```ruby
   class User < ActiveRecord::Base
     before_validation :assign_uuid, on: :create
     
     tokenize_pii fields: [:email],
                 entity_type: 'USER',
                 entity_id: ->(user) { user.uuid }
                 
     private
     
     def assign_uuid
       self.uuid ||= SecureRandom.uuid
     end
   end
   ```

3. **Add debugging to verify entity_id values:**
   ```ruby
   # Temporary debugging
   entity_id: ->(user) {
     value = user.id.to_s
     Rails.logger.debug "Entity ID for user: #{value.inspect}"
     value
   }
   ```

4. **Verify consistency in records:**
   ```ruby
   User.find_each do |user|
     puts "User #{user.id}: entity_id = #{user.send(:entity_id).inspect}"
   end
   ```

### Changing Entity ID Values

**Symptoms:**
- Unable to decrypt previously tokenized data
- Tokenized values change unexpectedly between operations

**Possible Causes:**
- The entity_id proc returns different values for the same record
- Logic change in entity_id calculation

**Solutions:**
1. Ensure your entity_id proc returns consistent values for the same record
2. If you need to change entity_id logic, plan a data migration strategy
3. Consider using database-stored UUIDs or other persistent identifiers

## Search and Query Issues 