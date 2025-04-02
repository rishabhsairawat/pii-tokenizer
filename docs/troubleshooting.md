# Troubleshooting Guide

This guide helps you diagnose and resolve common issues when working with PiiTokenizer.

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
- `encrypt_tokenized_fields` callback not running
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
   user.encrypt_tokenized_fields  # Call explicitly
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
     
     user.encrypt_tokenized_fields
     user.save(validate: false)
   end
   ```

3. Monitor progress and resume from failures:
   ```bash
   # Note last successful ID
   last_id = User.where.not(first_name_token: nil).maximum(:id)
   
   # Resume from that point
   User.where("id > ?", last_id).find_each do |user|
     user.encrypt_tokenized_fields
     user.save(validate: false)
   end
   ```

### Rails Version Compatibility

**Symptoms:**
- Undefined method errors
- ActiveRecord integration issues
- Migration generator errors

**Causes:**
- Rails version incompatibility
- API changes between Rails versions

**Solutions:**
1. Check compatibility in your Gemfile:
   ```ruby
   gem 'pii_tokenizer', '~> x.y.z'  # Use version compatible with your Rails
   ```

2. Use version-specific code paths:
   ```ruby
   if Rails.version >= '6.0'
     # Rails 6+ code
   else
     # Older Rails code
   end
   ```

3. Check for Rails-version specific initializers:
   ```ruby
   # config/initializers/pii_tokenizer.rb
   PiiTokenizer.configure do |config|
     config.rails_version = Rails.version  # If supported by the gem
   end
   ```

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