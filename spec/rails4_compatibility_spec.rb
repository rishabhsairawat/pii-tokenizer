require 'spec_helper'

RSpec.describe 'Rails 4.2 compatibility' do
  # Create an isolated testing environment for Rails 4.2 compatibility
  before(:all) do
    # Create a test class that mimics Rails 4 behavior
    @test_class = Class.new do
      def self.class_attribute(*args)
        args.each do |arg|
          singleton_class.class_eval do
            attr_accessor arg
          end
        end
      end
      
      def self.after_initialize(*args); end
      def self.after_find(*args); end
      def self.before_save(*args); end
      def self.after_save(*args); end
      
      # Include the tokenizable module directly
      include PiiTokenizer::Tokenizable
    end
  end
  
  it "initializes tokenized_fields with an empty array in a Rails 4 compatible way" do
    # The tokenized_fields should be initialized as an empty array
    expect(@test_class.tokenized_fields).to eq([])
  end
end 