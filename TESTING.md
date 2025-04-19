# Testing Guide

This document provides instructions for running tests for the PiiTokenizer gem across different Rails versions.

## Setup

Before running tests, make sure you've installed all dependencies:

```bash
bundle install
bundle exec appraisal install
```

This will install the main gem dependencies and create gemfiles for each Rails version we support.

## Running Tests

### Run tests for all Rails versions

To run tests for all supported Rails versions:

```bash
bundle exec rake all_rails
```

### Run tests for specific Rails versions

To run tests for a specific Rails version:

```bash
# Run Rails 4.2 tests
bundle exec rake rails4

# Run Rails 5.2 tests
bundle exec rake rails5
```

You can also run the tests directly with appraisal:

```bash
# Rails 4.2
bundle exec appraisal rails-4.2 rspec


# Rails 5.2
bundle exec appraisal rails-5.2 rspec
```

## Rails 4.2 Compatibility

The PiiTokenizer gem includes specialized handling for Rails 4.2 compatibility. To test just the Rails 4.2 compatibility features, you can run:

```bash
bundle exec rspec spec/rails4_compatibility_spec.rb -f d
```

This dedicated test file verifies that:
- Class attributes are properly initialized in a Rails 4.2 environment
- Token fields are correctly handled in Rails 4.2's different method calling patterns
- Dynamic finders work correctly with tokenized fields in Rails 4.2

The implementation leverages:
- A centralized `VersionCompatibility` module that handles Rails version detection
- Special handling for `method_missing` to intercept Rails 4.2-specific method calls
- Smart fallbacks for Rails 4.2's different approach to ActiveRecord method visibility

## Debugging

If you encounter issues with specific Rails versions:

1. Try running with more verbose output:
   ```bash
   bundle exec appraisal rails-4.2 rspec --format documentation
   ```

2. If you need to debug, you can use pry:
   ```bash
   bundle exec appraisal rails-4.2 rspec --format documentation --debug
   ```

3. For specific Rails 4.2 compatibility issues, try running just the Rails 4.2 specs:
   ```bash
   bundle exec appraisal rails-4.2 rspec spec/rails4_compatibility_spec.rb --format documentation
   ```

## Adding Tests for New Rails Versions

To add support for a new Rails version:

1. Edit the `Appraisals` file to add a new Rails version.
2. Run `bundle exec appraisal install` to generate the gemfile.
3. Update the Rakefile if you want to add a specific rake task for the new version.
4. Run the tests to ensure compatibility.

## Test Files

Important test files:

- `spec/rails_version_compatibility_spec.rb`: Specifically tests behavior across Rails versions
- `spec/rails4_compatibility_spec.rb`: Tests specific Rails 4.2 compatibility features
- `spec/support/bigdecimal_patch.rb`: Compatibility patch for Rails 4.2 with Ruby 2.4+
- `spec/support/database_setup.rb`: Database setup that works across Rails versions
- `spec/dual_write_spec.rb`: Tests dual-write mode across different Rails versions
- `spec/after_save_bug_spec.rb`: Tests for save callbacks across Rails versions 