#!/usr/bin/env ruby
# Debug script for PiiTokenizer clearing nil values

require 'bundler/setup'
require 'pii_tokenizer'
require 'active_record'

# Enable debug output
ENV['DEBUG'] = 'true'

# Configure database
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

# Create tables for testing
ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :first_name
    t.string :first_name_token
    t.string :last_name
    t.string :last_name_token
  end
end

# Define encryption service
class TestEncryptionService
  def encrypt_batch(tokens_data)
    result = {}
    tokens_data.each do |data|
      key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}"
      result[key] = "token_for_#{data[:value]}"
    end
    result
  end

  def decrypt_batch(tokens)
    result = {}
    tokens = [tokens] unless tokens.is_a?(Array)
    tokens.each do |token|
      if token.to_s.start_with?('token_for_')
        original_value = token.to_s.sub('token_for_', '')
        result[token] = original_value
      end
    end
    result
  end

  def search_tokens(value)
    ["token_for_#{value}"]
  end
end

# Configure PiiTokenizer to use test encryption service
module PiiTokenizer
  def self.encryption_service
    @encryption_service ||= TestEncryptionService.new
  end
end

# Define User model
class User < ActiveRecord::Base
  include PiiTokenizer::Tokenizable

  tokenize_pii(
    fields: {
      first_name: 'FIRST_NAME',
      last_name: 'LAST_NAME'
    },
    entity_type: 'customer',
    entity_id: ->(record) { "User_customer_#{record.id}" },
    dual_write: false,
    read_from_token: true
  )
end

puts "==== Creating user with first_name='John' ===="
user = User.create!(first_name: 'John', last_name: 'Doe')
puts "User ID: #{user.id}"
puts "user.first_name = #{user.first_name.inspect}"
puts "user.first_name_token = #{user.first_name_token.inspect}"
puts "DB first_name: #{user.read_attribute(:first_name).inspect}"

puts "\n==== Setting first_name to nil ===="
user.first_name = nil
puts "Before save: user.first_name = #{user.first_name.inspect}"
puts "Changes before save: #{user.changes.inspect}"

# Add this to help debug - directly update the instance variable
user.instance_variable_set('@original_first_name', nil)

user.save!
puts "After save: user.first_name = #{user.first_name.inspect}"
puts "After save: user.first_name_token = #{user.first_name_token.inspect}"

puts "\n==== Reloading user ===="
user.reload
puts "After reload: user.first_name = #{user.first_name.inspect}"
puts "After reload: user.first_name_token = #{user.first_name_token.inspect}"
puts "DB first_name: #{user.read_attribute(:first_name).inspect}"

puts "\n==== Testing with dual_write=true ===="
User.dual_write_enabled = true
user2 = User.create!(first_name: 'Jane', last_name: 'Smith')
puts "User ID: #{user2.id}"
puts "user2.first_name = #{user2.first_name.inspect}"
puts "user2.first_name_token = #{user2.first_name_token.inspect}"
puts "DB first_name: #{user2.read_attribute(:first_name).inspect}"

puts "\n==== Setting first_name to nil with dual_write=true ===="
user2.first_name = nil
puts "Before save: user2.first_name = #{user2.first_name.inspect}"
user2.save!
puts "After save: user2.first_name = #{user2.first_name.inspect}"
puts "After save: user2.first_name_token = #{user2.first_name_token.inspect}"

puts "\n==== Reloading user2 ===="
user2.reload
puts "After reload: user2.first_name = #{user2.first_name.inspect}"
puts "After reload: user2.first_name_token = #{user2.first_name_token.inspect}"
puts "DB first_name: #{user2.read_attribute(:first_name).inspect}"
