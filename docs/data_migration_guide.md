# Data Migration Guide

This guide outlines a step-by-step approach for migrating existing data from plaintext to tokenized storage using PiiTokenizer.

## Overview of the Migration Process

PiiTokenizer supports a dual-write strategy that allows for a gradual, safe migration:

1. **Set Up Token Columns**: Add token columns to your database
2. **Configure Dual-Write Mode**: Set up models to write to both original and token columns
3. **Backfill Existing Data**: Convert existing plaintext data to tokens
4. **Add Token Indices**: Create database indices for token columns
5. **Switch to Reading from Tokens**: Configure models to read from token columns
6. **Stop Writing Plaintext**: Configure models to stop writing to original columns
7. **Remove Plaintext Data**: Clean up plaintext data

## Detailed Migration Steps

### Phase 1: Setting Up Token Columns

First, add token columns to your database tables without indices (for faster backfill):

```bash
# Generate a migration to add token columns
$ rails generate pii_tokenizer:token_columns user first_name last_name email
```

This generates a migration like:

```ruby
class AddUserTokenColumns < ActiveRecord::Migration
  def change
    add_column :users, :first_name_token, :string
    add_column :users, :last_name_token, :string
    add_column :users, :email_token, :string
  end
end
```

Run the migration:

```bash
$ rails db:migrate
```

### Phase 2: Configure for Dual-Write Mode

Update your model configuration to enable dual-write mode:

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
  dual_write: true,       # Write to both original and token columns
  read_from_token: false  # Continue reading from original columns
end
```

At this point:
- New records will have both original and token columns populated
- Existing records will still have empty token columns
- All reads will come from original columns

### Phase 3: Backfill Existing Data

Use the provided Rake task to backfill token columns for existing records:

```bash
# Process User records in batches of 1000
$ rake pii_tokenizer:backfill[User,1000]
```

This task:
1. Processes records in batches
2. Tokenizes plaintext values
3. Stores tokens in the corresponding token columns
4. Preserves original column data
5. Provides progress updates during execution

The backfill task is designed to be resumable - if interrupted, you can run it again and it will only process records that still need tokenization.

### Phase 4: Add Indices to Token Columns

Once backfill is complete, add indices to the token columns for query performance:

```bash
# Generate a migration to add indices
$ rails generate pii_tokenizer:token_indices user first_name last_name email
```

This generates a migration like:

```ruby
class AddUserTokenIndices < ActiveRecord::Migration
  # Disable DDL transactions for PostgreSQL concurrent indexing
  disable_ddl_transaction!

  def change
    # Create indices concurrently on PostgreSQL, or normally on other databases
    if connection.adapter_name.downcase.include?('postgresql')
      add_index :users, :first_name_token, algorithm: :concurrently
      add_index :users, :last_name_token, algorithm: :concurrently
      add_index :users, :email_token, algorithm: :concurrently
    else
      add_index :users, :first_name_token
      add_index :users, :last_name_token
      add_index :users, :email_token
    end
  end
end
```

Run the migration:

```bash
$ rails db:migrate
```

### Phase 5: Switch to Reading from Token Columns

Update your model to read from token columns:

```ruby
tokenize_pii fields: {
  first_name: 'NAME',
  last_name: 'NAME',
  email: 'EMAIL'
},
entity_type: 'USER',
entity_id: ->(record) { record.id.to_s },
dual_write: true,       # Continue writing to both columns
read_from_token: true   # Now read from token columns
```

At this point:
- All reads will come from token columns (which are decrypted on access)
- Writes will still go to both original and token columns
- You should monitor your application for any issues with the new setup

### Phase 6: Stop Writing to Original Columns

Once you're confident everything is working correctly with token columns, update your model to stop writing to original columns:

```ruby
tokenize_pii fields: {
  first_name: 'NAME',
  last_name: 'NAME',
  email: 'EMAIL'
},
entity_type: 'USER',
entity_id: ->(record) { record.id.to_s },
dual_write: false,      # Stop writing to original columns
read_from_token: true   # Continue reading from token columns
```

At this point:
- New or updated records will only have token columns populated
- Original columns will be set to nil on save
- All reads will continue to come from token columns

### Phase 7: Remove Plaintext Data (Optional)

For complete PII protection, you may want to clear plaintext data from original columns:

```ruby
# Create a migration to clear plaintext data
class RemovePlaintextData < ActiveRecord::Migration[6.0]
  def up
    # Process in batches to avoid locking the entire table
    User.in_batches do |batch|
      batch.update_all(
        first_name: nil,
        last_name: nil,
        email: nil
      )
    end
  end

  def down
    # No rollback possible once data is deleted
    raise ActiveRecord::IrreversibleMigration
  end
end
```

Run the migration:

```bash
$ rails db:migrate
```

## Monitoring and Validation

Throughout this process, you should:

1. **Test thoroughly** at each phase before moving to the next
2. **Monitor application performance** for any significant changes
3. **Verify data integrity** by comparing plaintext and decrypted values
4. **Have a rollback plan** in case you encounter issues

## Handling Edge Cases

### Large Datasets

For very large datasets, consider:
- Running the backfill process during low-traffic periods
- Breaking the backfill into smaller segments (by ID ranges)
- Using database partitioning for more efficient processing

### Custom Validation Logic

If your application has custom validation logic that relies on the plaintext fields:
1. Update those validations to use the accessor methods, which will transparently decrypt
2. Test thoroughly to ensure validation behavior remains unchanged

## Next Steps

- [Best Practices](best_practices.md): Recommendations for working with tokenized data
- [API Reference](api_reference.md): Detailed information on PiiTokenizer's methods 