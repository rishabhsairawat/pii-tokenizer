# BigDecimal compatibility patch for Rails 4.2 with Ruby 2.4+
# Rails 4.2 still uses BigDecimal.new but Ruby 2.4+ deprecated it
if RUBY_VERSION >= '2.4.0'
  require 'bigdecimal'
  
  # Monkeypatch BigDecimal to support Rails 4.2
  BigDecimal.class_eval do
    def self.new(*args)
      BigDecimal(*args)
    end
  end
end 