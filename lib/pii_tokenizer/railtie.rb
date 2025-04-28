module PiiTokenizer
  # Check if we're using Rails
  if defined?(Rails::Railtie)
    class Railtie < Rails::Railtie
      initializer 'pii_tokenizer.configure_rails_initialization' do
        # Nothing special needed here, just making sure the gem is loaded
      end

      # Generate an initializer template when installing the gem
      generators do
        require 'rails/generators/base'

        class InstallGenerator < Rails::Generators::Base
          source_root File.expand_path('templates', __dir__)

          def copy_initializer
            template 'initializer.rb', 'config/initializers/pii_tokenizer.rb'
          end
        end
      end
    end
  end
end
