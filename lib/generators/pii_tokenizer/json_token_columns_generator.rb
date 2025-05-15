require 'rails/generators'
require 'rails/generators/active_record'

module PiiTokenizer
  class JsonTokenColumnsGenerator < Rails::Generators::NamedBase
    include Rails::Generators::Migration

    source_root File.expand_path('templates', __dir__)

    argument :json_fields, type: :array, default: [], banner: 'json_field json_field'

    class_option :column_type, type: :string, default: 'json',
                               desc: 'Column type for JSON token columns (text recommended for compatibility)'

    def self.next_migration_number(dirname)
      ActiveRecord::Generators::Base.next_migration_number(dirname)
    end

    def create_migration_file
      migration_template 'json_migration.rb.erb', "db/migrate/add_#{file_name}_json_token_columns.rb"
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

    def column_type
      options[:column_type]
    end
  end
end
