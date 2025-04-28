# Rails Version Compatibility

PiiTokenizer is fully compatible with Rails 4.2+ through Rails 5.2.x. This document details how the gem handles version-specific differences and ensures consistent behavior across all supported Rails versions.

## Supported Rails Versions [Only tested for these versions]

- Rails 4.2.x
- Rails 5.2.x

## Automatic Compatibility Features

PiiTokenizer includes specialized handling for Rails version differences:

### Changes Tracking

The way Rails tracks attribute changes varies between versions:

- **Rails 5+**: `previous_changes` contains changes after a save operation
- **Rails 4**: `changes` contains these changes during the save process

PiiTokenizer automatically detects your Rails version and uses the appropriate method:

```ruby
# Internal implementation
def active_changes
  if rails5_or_newer?
    respond_to?(:previous_changes) ? previous_changes : {}
  else
    respond_to?(:changes) ? changes : {}
  end
end
```

### Method Visibility Differences

Some core Rails methods have different visibility (private/public) across versions:

- `write_attribute` is public in some versions and private in others
- `update_record` has visibility differences across versions

PiiTokenizer safely handles these differences:

```ruby
# Safe wrapper that works in both Rails 4 and 5+
def safe_write_attribute(attribute, value)
  if rails5_or_newer?
    begin
      write_attribute(attribute, value)
    rescue NoMethodError
      send(:write_attribute, attribute, value) if respond_to?(:write_attribute, true)
    end
  else
    send(:write_attribute, attribute, value)
  end
  
  value
end
```

### Field Change Detection

PiiTokenizer provides a consistent API for detecting field changes regardless of Rails version:

```ruby
# In your code
user.field_changed?(:email)  # Works the same in Rails 4.2, 5.x, and 6.x
```

## Version Detection

PiiTokenizer uses internal helpers to detect the running Rails version:

```ruby
# Check for Rails 5+
def rails5_or_newer?
  @rails5_or_newer ||= ::ActiveRecord::VERSION::MAJOR >= 5
end

# Check for Rails 4.2 specifically
def rails4_2?
  ::ActiveRecord::VERSION::MAJOR == 4 && ::ActiveRecord::VERSION::MINOR == 2
end
```

## Specific Compatibility Features

### Rails 4.2 Compatibility

For Rails 4.2, PiiTokenizer handles:

- Different method implementations for record updates and inserts
- Special handling for `changes` tracking
- Class attribute initialization differences

### Rails 5.x Features

For newer Rails versions, PiiTokenizer provides:

- Optimized callbacks for record lifecycle events
- Complete compatibility with the newer ActiveRecord API 
- Support for the enhanced attribute API

## Testing Against Multiple Rails Versions

PiiTokenizer is thoroughly tested against all supported Rails versions to ensure compatibility. You can verify this by running:

```bash
# Test against Rails 4.2
bundle exec rake rails4

# Test against Rails 5.2
bundle exec rake rails5


# Test against all supported Rails versions
bundle exec rake all_rails
```

## How This Affects Your Code

The good news is that you don't need to worry about these compatibility details. PiiTokenizer handles them internally, so your code will work the same way across all supported Rails versions. You can write your models and use tokenization without concern for version-specific behavior.

Example model that works across all supported Rails versions:

```ruby
class User < ActiveRecord::Base  # Works in Rails 4.2
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
    first_name: 'NAME',
    email: 'EMAIL' 
  },
  entity_type: 'USER',
  entity_id: ->(user) { user.id.to_s }
end
```

```ruby
class Profile < ApplicationRecord  # Works in Rails 5+
  include PiiTokenizer::Tokenizable
  
  tokenize_pii fields: {
    full_name: 'NAME',
    phone: 'PHONE'
  },
  entity_type: 'PROFILE',
  entity_id: ->(profile) { profile.id.to_s }
end
``` 