# Handle different Rails versions and their database setup requirements
require 'active_record'

# Don't output migration messages during tests
ActiveRecord::Migration.verbose = false

# Use appropriate parent class based on Rails version
MIGRATION_CLASS = if ActiveRecord::VERSION::MAJOR >= 5
                    ActiveRecord::Migration[ActiveRecord::VERSION::STRING.to_f]
                  else
                    ActiveRecord::Migration
                  end

# Database setup that works with both Rails 4 and 5
module DatabaseHelpers
  def self.setup_database
    # Set up an in-memory database for testing
    ActiveRecord::Base.establish_connection(
      adapter: 'sqlite3',
      database: ':memory:'
    )

    # Create test tables
    ActiveRecord::Schema.define do
      create_table :users, force: true do |t|
        t.string :first_name
        t.string :last_name
        t.string :email

        # Add token columns
        t.string :first_name_token
        t.string :last_name_token
        t.string :email_token

        t.timestamps null: false
      end

      create_table :internal_users, force: true do |t|
        t.string :first_name
        t.string :last_name
        t.string :role

        # Add token columns
        t.string :first_name_token
        t.string :last_name_token

        t.timestamps null: false
      end

      create_table :contacts, force: true do |t|
        t.string :full_name
        t.string :phone_number
        t.string :email_address

        # Add token columns
        t.string :full_name_token
        t.string :phone_number_token
        t.string :email_address_token

        t.timestamps null: false
      end
    end
  end
end

# Set up the database
DatabaseHelpers.setup_database 