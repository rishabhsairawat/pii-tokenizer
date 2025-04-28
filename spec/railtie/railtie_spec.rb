require 'spec_helper'

# Only run these tests if Rails is defined
if defined?(Rails)
  RSpec.describe PiiTokenizer::Railtie do
    it 'is a Rails::Railtie' do
      expect(described_class.ancestors).to include(Rails::Railtie)
    end

    it 'has an initializer for pii_tokenizer' do
      initializers = described_class.initializers
      initializer = initializers.find { |i| i.name == 'pii_tokenizer.configure_rails_initialization' }
      expect(initializer).not_to be_nil
    end

    it 'includes the generators' do
      generator_names = Rails::Generators.lookup('pii_tokenizer:install').map { |gen| gen.name.split('::').last }
      expect(generator_names).to include('InstallGenerator')
    end
  end
end
