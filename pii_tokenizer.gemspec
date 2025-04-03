lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'pii_tokenizer/version'

Gem::Specification.new do |spec|
  spec.name          = 'pii_tokenizer'
  spec.version       = PiiTokenizer::VERSION
  spec.authors       = ['Rishabh Sairawat']
  spec.email         = ['rishabhsairawat01@gmail.com']

  spec.summary       = 'Tokenize PII fields in ActiveRecord models'
  spec.description   = 'A gem for encrypting and decrypting PII fields in ActiveRecord models ' \
                      'using an external encryption service with batch processing support'
  spec.homepage      = 'https://github.com/rishabhsairawat/pii_tokenizer'
  spec.license       = 'MIT'

  spec.files         = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 2.4.1'

  spec.add_dependency 'activerecord', '>= 4.2', '< 6.0'
  spec.add_dependency 'activesupport', '>= 4.2', '< 6.0'
  spec.add_dependency 'faraday', '>= 0.17.3', '< 2.0'

  spec.add_development_dependency 'bundler', '>= 1.17', '< 3.0'
  spec.add_development_dependency 'pry', '~> 0.14'
  spec.add_development_dependency 'rake', '~> 12.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rubocop', '~> 0.81.0'
  spec.add_development_dependency 'rubocop-rspec', '~> 1.38.0'
  spec.add_development_dependency 'simplecov', '~> 0.18.5'
  spec.add_development_dependency 'sqlite3', '~> 1.3.6'
  spec.add_development_dependency 'webmock', '~> 3.0'
end
