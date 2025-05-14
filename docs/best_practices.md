# Best Practices for PiiTokenizer

This document outlines recommended practices for using PiiTokenizer effectively and securely in your Rails applications.

## Security Considerations

### Protecting Your Encryption Service

- **Use HTTPS** for all communication with your encryption service
- **Implement authentication** for your encryption service API
- **Restrict network access** to your encryption service where possible
- **Monitor API access** to detect unusual patterns or potential breaches

### Handling Tokenized Data

- **Never log tokenized values** as they represent encrypted PII
- **Limit access** to database tables containing tokenized data
- **Encrypt database backups** that contain tokenized data
- **Consider database column-level encryption** as an additional security layer

### Secure Storage of Sensitive Data

- **Avoid plaintext PII in databases** as it represents a security risk even for brief moments
- **Take advantage of PiiTokenizer's secure save operations** which prevent plaintext storage:
  ```ruby
  # PiiTokenizer keeps data in memory during save and only persists tokens
  User.create(email: 'sensitive@example.com') 
  
  # Same security for find_or_create_by
  User.find_or_create_by(email: 'new_user@example.com')
  ```
- **Never bypass the save mechanisms** by calling direct database operations with unencrypted PII values
- **Remember all standard methods** (`create`, `save`, `save!`, `find_or_create_by`) are already secure
- **Keep sensitive data encrypted end-to-end** in your application
- **Double-check all data export functionality** to ensure PII isn't accidentally exported

## Reliable Entity ID Strategies

The PII Tokenizer requires a unique entity identifier for each record that must be available during the tokenization process. This is a critical requirement for the system to work properly.

### Entity ID Best Practices

- **Always ensure entity_id is available** during model save operations, even for new records
- **Use UUIDs or other pre-assigned identifiers** when possible instead of database-generated IDs
- **Consider composite IDs** that remain stable throughout a record's lifecycle
- **Never return nil or empty string** from your entity_id proc

### Example Entity ID Strategies

1. **Using UUID as primary key**:
   ```ruby
   class User < ActiveRecord::Base
     include PiiTokenizer::Tokenizable
     
     # Generate UUID before validation
     before_validation :assign_uuid, on: :create
     
     tokenize_pii fields: [:email, :phone],
                 entity_type: 'USER',
                 entity_id: ->(user) { user.uuid }
                 
     private
     
     def assign_uuid
       self.uuid ||= SecureRandom.uuid
     end
   end
   ```

2. **Using business identifiers**:
   ```ruby
   class Customer < ActiveRecord::Base
     include PiiTokenizer::Tokenizable
     
     # Generate customer number before save
     before_validation :assign_customer_number, on: :create
     
     tokenize_pii fields: [:name, :address],
                 entity_type: 'CUSTOMER',
                 entity_id: ->(customer) { customer.customer_number }
                 
     private
     
     def assign_customer_number
       self.customer_number ||= "CUST-#{SecureRandom.hex(6).upcase}"
     end
   end
   ```

3. **Using composite identifiers when database ID is required**:
   ```ruby
   class Order < ActiveRecord::Base
     include PiiTokenizer::Tokenizable
     
     belongs_to :user
     
     tokenize_pii fields: [:shipping_address, :billing_address],
                 entity_type: 'ORDER',
                 entity_id: ->(order) { 
                   if order.id.present?
                     "order-#{order.id}"
                   else
                     "order-temp-#{order.user_id}-#{Time.now.to_i}"
                   end
                 }
   end
   ```

### Troubleshooting Entity ID Issues

If you're experiencing issues with tokenization, check:

- **Verify your entity_id proc returns a value** for both new and existing records
- **Inspect the actual value returned** by your entity_id proc at runtime
- **Ensure entity_id values are consistent** across save operations for the same record
- **Check for nil or empty values** that might be returned in edge cases

## Performance Optimization

### Batch Processing

- **Use batch operations** for encrypting and decrypting multiple fields
- **Optimize batch sizes** based on your application's needs (default is 100)
- **Process large datasets** in background jobs when possible

```ruby
# Instead of individual decryption (causes N+1 API calls)
users.each do |user|
  puts user.first_name  # Triggers individual decryption
end

# Better: Batch decrypt fields for multiple records
# This makes a single API call instead of one per record
users = User.where(id: user_ids).include_decrypted_fields(:first_name)
users.each do |user|
  puts user.first_name  # Uses cached value, no API call
end

# Alternative: Preload decryption for existing records
users = User.where(id: user_ids).to_a
User.preload_decrypted_fields(users, :first_name, :last_name)
```

### Working With Collections

When working with multiple records, always use the batch processing methods to minimize API calls:

1. **For ActiveRecord queries:**
   ```ruby
   # Chained with other scopes
   active_users = User.active.include_decrypted_fields(:email, :first_name)
   
   # With associations
   company.users.include_decrypted_fields(:email)
   ```

2. **For existing collections:**
   ```ruby
   users = User.where(created_at: 1.day.ago..Time.now).to_a
   User.preload_decrypted_fields(users, :first_name, :last_name, :email)
   ```

3. **Handling associations:**
   ```ruby
   companies = Company.includes(:users).limit(10)
   
   # Preload user fields after loading the association
   user_records = companies.flat_map(&:users)
   User.preload_decrypted_fields(user_records, :email)
   ```

### Caching

- **Enable model-level caching** for frequently accessed decrypted values
- **Clear caches appropriately** when tokenized data changes
- **Be cautious with caching** in distributed environments

## Database Considerations

### Indexing Strategy

- **Add indices to token columns** that are frequently used in queries
- **Use the token_indices generator** to create appropriate indices
- **Consider partial indices** for columns with many NULL values

### Query Optimization

- **Query using token columns directly** when possible rather than decrypting all records
- **Use bulk operations** for updates that affect tokenized fields
- **Be cautious with ORDER BY** on tokenized columns (sorting will be by token, not actual value)

## Migration Strategies

### Gradual Transition

- **Use the dual-write approach** during migration (see [Data Migration Guide](data_migration_guide.md))
- **Test thoroughly** at each phase before proceeding
- **Monitor application performance** during and after migration

### Testing During Migration

- **Create test cases** that verify both old and new data access patterns
- **Validate data integrity** by comparing plaintext and tokenized values
- **Simulate failures** to ensure your rollback strategy works

## Custom PII Types

### Defining Custom Types

- **Be consistent with type naming** across your application
- **Document your custom PII types** for team reference
- **Consider regulatory requirements** when defining custom types

```ruby
# Example of consistent PII type naming
tokenize_pii fields: {
  medical_record_number: 'HEALTH_ID',
  national_id: 'GOV_ID',
  passport_number: 'GOV_ID'
}
```

### Working with Complex Data

- **Serialize complex data** before tokenization if necessary
- **Consider field-level tokenization** for structured data like addresses
- **Document your serialization approach** for maintainability

## Testing

### Unit Tests

- **Mock the encryption service** in your tests for speed
- **Test both encryption and decryption** pathways
- **Verify behavior** with both `dual_write` enabled and disabled
- **Test `read_from_token` behavior** in both states

```ruby
# Example test helper for mocking the encryption service
RSpec.configure do |config|
  config.before(:each) do
    mock_encryption_service = instance_double(PiiTokenizer::EncryptionService)
    
    allow(mock_encryption_service).to receive(:encrypt_batch) do |data|
      data.each_with_object({}) do |item, result|
        key = "#{item[:entity_type]}:#{item[:entity_id]}:#{item[:pii_type]}"
        result[key] = "encrypted_#{item[:value]}"
      end
    end
    
    allow(mock_encryption_service).to receive(:decrypt_batch) do |tokens|
      tokens.each_with_object({}) do |token, result|
        if token.start_with?("encrypted_")
          result[token] = token.sub("encrypted_", "")
        end
      end
    end
    
    allow(PiiTokenizer::EncryptionService).to receive(:new).and_return(mock_encryption_service)
  end
end
```

### Integration Tests

- **Test the actual encryption service integration** in CI/CD pipelines
- **Create fixtures with tokenized data** for integration testing
- **Verify migration scripts** with production-like data volumes

## Code Organization

### Model Structure

- **Group tokenized fields logically** in your model definitions
- **Keep configuration consistent** across similar models
- **Document the purpose** of each tokenized field

```ruby
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable
  
  # Personal Identification Information
  tokenize_pii fields: {
    # Personal identification
    first_name: 'NAME',
    last_name: 'NAME',
    
    # Contact information
    email: 'EMAIL',
    phone: 'PHONE',
    
    # Financial information
    bank_account: 'FINANCIAL_ACCOUNT'
  },
  entity_type: 'USER',
  entity_id: ->(record) { record.id.to_s }
end
```

### Configuration Management

- **Use environment variables** for encryption service URL
- **Set reasonable defaults** for configuration options
- **Document configuration choices** in your initializer

## Troubleshooting

### Common Issues

- **Missing token columns**: Ensure migrations have been run
- **Unexpected nil values**: Check if fields are being encrypted/decrypted correctly
- **Performance issues**: Check batch sizes and API response times
- **Encryption service errors**: Verify connectivity and authentication

### Debugging

- **Enable debug logging** temporarily for troubleshooting
- **Validate encrypted values format** to ensure proper encryption
- **Check dual-write behavior** is working as expected

## Compliance and Auditing

### Audit Trail

- **Log access to decrypted data** when required for compliance
- **Track encryption/decryption operations** for sensitive data
- **Maintain records** of which fields contain what type of PII

### Regulatory Compliance

- **Document mapping** between tokenized fields and regulatory categories (GDPR, HIPAA, etc.)
- **Create data retention policies** for tokenized data
- **Implement data subject access requests** (DSAR) handling

## Next Steps

- [API Reference](api_reference.md): Complete API documentation
- [Data Migration Guide](data_migration_guide.md): Detailed migration instructions 