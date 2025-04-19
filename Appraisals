appraise 'rails-4.2' do
  gem 'activerecord', '~> 4.2.0'
  gem 'activesupport', '~> 4.2.0'
  # Add specific gems with versions for Rails 4.2 compatibility
  gem 'sqlite3', '~> 1.3.6' # Newer versions not compatible with AR 4.2
  gem 'json', '< 2.0' if RUBY_VERSION >= '2.4.0' # For older Rails with newer Ruby
end

appraise 'rails-5.0' do
  gem 'activerecord', '~> 5.0.0'
  gem 'activesupport', '~> 5.0.0'
end

appraise 'rails-5.2' do
  gem 'activerecord', '~> 5.2.0'
  gem 'activesupport', '~> 5.2.0'
end
