lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pii_tokenizer/version"

Gem::Specification.new do |spec|
  spec.name          = "pii_tokenizer"
  spec.version       = PiiTokenizer::VERSION
  spec.authors       = ["Rishabh Sairawat"]
  spec.email         = ["rishabh.sairawat@housing.com"]

  spec.summary       = %q{Tokenize PII attributes in ActiveRecord models}
  spec.description   = %q{A gem for encrypting and decrypting PII fields in ActiveRecord models using an external encryption service with batch processing support}
  spec.homepage      = "https://github.com/rishabhsairawat/pii_tokenizer"
  spec.license       = "MIT"

  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 2.4.1"

  spec.add_dependency "activesupport", ">= 5.0", "< 6.0"
  spec.add_dependency "activerecord", ">= 5.0", "< 6.0"
  spec.add_dependency "faraday", "~> 0.15"

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 12.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "sqlite3", "~> 1.3.6"
end 