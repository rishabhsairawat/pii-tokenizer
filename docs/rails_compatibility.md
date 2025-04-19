# Rails Compatibility

PiiTokenizer is designed to work seamlessly across multiple Rails versions, from Rails 4.2 through the latest Rails 6.x releases. This document explains how PiiTokenizer handles version-specific differences and ensures compatibility across all supported Rails versions.

## Supported Rails Versions

PiiTokenizer supports:
- Rails 4.2.x
- Rails 5.0.x
- Rails 5.1.x
- Rails 5.2.x
- Rails 6.0.x
- Rails 6.1.x

## Rails Version Differences

Several key differences exist between Rails versions that affect how PiiTokenizer works:

### 1. Changes Tracking

Rails 4.2 and Rails 5+ handle changes tracking differently:

- **Rails 4.2**: Uses the `changes` hash to track changes after a save operation
- **Rails 5+**: Uses the `previous_changes` hash to track changes after a save operation

PiiTokenizer handles this seamlessly through the `field_changed?` and `active_changes` helper methods:

```ruby
# Instead of:
if rails5_or_newer?
  respond_to?(:previous_changes) && previous_changes.key?(field_str)
else
  respond_to?(:changes) && changes.key?(field_str)
end

# You can use:
field_changed?(field)
```

### 2. Method Visibility

Method visibility differs between Rails versions:

- **Rails 4.2**: Methods like `write_attribute` are private
- **Rails 5+**: These methods are public

PiiTokenizer handles this through the `safe_write_attribute` method which adapts to the Rails version:

```ruby
def safe_write_attribute(attribute, value)
  if rails5_or_newer?
    write_attribute(attribute, value)
  else
    send(:write_attribute, attribute, value)
  end
end
```

### 3. ActiveRecord Method Implementations

Rails 4.2 uses different implementations for some core ActiveRecord methods:

- **insert**: Used during record creation
- **_update_record**: Used during record updates

PiiTokenizer uses a specialized `method_missing` approach to intercept these calls in Rails 4.2 and maintain consistent behavior with Rails 5+.

## Rails 4.2 Compatibility

PiiTokenizer takes particular care to ensure Rails 4.2 compatibility:

### VersionCompatibility Module

The `VersionCompatibility` module centralizes all Rails version detection:

```ruby
module VersionCompatibility
  def rails5_or_newer?
    @rails5_or_newer ||= ::ActiveRecord::VERSION::MAJOR >= 5
  end

  def rails4_2?
    ::ActiveRecord::VERSION::MAJOR == 4 && ::ActiveRecord::VERSION::MINOR == 2
  end
  
  def active_record_version
    "#{::ActiveRecord::VERSION::MAJOR}.#{::ActiveRecord::VERSION::MINOR}"
  end
end
```

### Dynamic Method Handling

PiiTokenizer uses a modular approach for maintaining compatibility:

```ruby
def handle_rails4_method?(method_name)
  return false unless rails4_2?
  [:insert, :_update_record].include?(method_name)
end

def method_missing(method_name, *args, &block)
  if handle_dynamic_finder?(method_name, *args)
    return handle_dynamic_finder(method_name, *args)
  end

  if handle_rails4_method?(method_name)
    return handle_rails4_method(method_name, *args)
  end

  super
end
```

### Class Attribute Initialization

Rails 4.2 initializes class attributes differently than Rails 5+. PiiTokenizer ensures that tokenized_fields and other attributes are properly initialized regardless of Rails version:

```ruby
included do
  class_attribute :tokenized_fields
  self.tokenized_fields = []
  
  # Other class attributes initialization
end
```

## Testing Rails Compatibility

PiiTokenizer includes comprehensive testing across all supported Rails versions:

```bash
# Test all Rails versions
bundle exec rake all_rails

# Test just Rails 4.2
bundle exec rake rails4

# Test Rails 4.2 compatibility specifically
bundle exec rspec spec/rails4_compatibility_spec.rb
```

## Best Practices for Version Compatibility

When using PiiTokenizer in a multi-version Rails environment:

1. Avoid direct usage of Rails version-specific methods like `previous_changes` or `changes`
2. Use PiiTokenizer's version-agnostic methods like `field_changed?` and `active_changes`
3. If you need to check Rails version in your own code:
   ```ruby
   if ::ActiveRecord::VERSION::MAJOR >= 5
     # Rails 5+ specific code
   else
     # Rails 4 specific code
   end
   ```

4. Run your test suite against multiple Rails versions if you support them

## Troubleshooting Version-Specific Issues

If you encounter Rails version-specific issues:

1. Verify which Rails version you're running: `Rails.version`
2. Check if the issue is related to changes tracking, method visibility, or class initialization
3. Look for Rails version-specific logs in your application
4. Test the issue in isolation using the Rails console
5. Review the [Rails 4.2 Compatibility Test](../spec/rails4_compatibility_spec.rb) for examples

For additional help with Rails compatibility issues, refer to the [Troubleshooting Guide](troubleshooting.md#rails-version-compatibility). 