require 'rails/generators'
require 'rails/generators/active_record'

module PiiTokenizer
  class TokenIndicesGenerator < Rails::Generators::NamedBase
    include Rails::Generators::Migration

    source_root File.expand_path('templates', __dir__)

    argument :attributes, type: :array, default: [], banner: 'field field field'

    def self.next_migration_number(dirname)
      ActiveRecord::Generators::Base.next_migration_number(dirname)
    end

    def create_migration_file
      migration_template 'index_migration.rb.erb', "db/migrate/add_#{file_name}_token_indices.rb"
    end

    private

    def migration_version
      if Rails::VERSION::MAJOR >= 5
        "[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]"
      else
        ''
      end
    end

    def migration_class_name
      file_name.camelize
    end

    def table_name
      file_name.tableize
    end
  end
end
