require 'spec_helper'

RSpec.describe PiiTokenizer::Tokenizable do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }

  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
  end

  describe 'token column name generation' do
    it 'properly generates token column name' do
      user = User.new(id: 1)
      expect(user.send(:token_column_for, :first_name)).to eq('first_name_token')
    end

    it 'handles symbol fields' do
      user = User.new(id: 1)
      expect(user.send(:token_column_for, :last_name)).to eq('last_name_token')
    end

    it 'handles string fields' do
      user = User.new(id: 1)
      expect(user.send(:token_column_for, 'email')).to eq('email_token')
    end
  end

  describe 'field operations' do
    it 'handles missing token columns gracefully' do
      # Create a model with a field that doesn't have a corresponding token column
      class NoTokenColumnUser
        include PiiTokenizer::Tokenizable

        tokenize_pii fields: %i[username],
                     entity_type: 'user',
                     entity_id: ->(record) { "User_#{record.id}" },
                     dual_write: false,
                     read_from_token: true

        attr_accessor :id, :username

        def initialize(id:, username:)
          @id = id
          @username = username
        end

        # Mimic ActiveRecord's column checks
        def has_attribute?(attr)
          respond_to?(attr)
        end

        # No *_token field exists
        def respond_to?(method, include_private = false)
          method != :username_token && super
        end
      end

      user = NoTokenColumnUser.new(id: 1, username: 'johndoe')

      # Should not error when accessing the field
      expect { user.username }.not_to raise_error

      # Should still return the original value
      expect(user.username).to eq('johndoe')
    end
  end

  describe 'attribute writers' do
    it 'sets instance variable and original value with attribute writer' do
      user = User.new(id: 1)
      user.first_name = 'Jane'

      # Check that both instance variable and original value are set
      expect(user.instance_variable_get(:@original_first_name)).to eq('Jane')
      expect(user.first_name).to eq('Jane')
    end

    it 'preserves case for values in writer' do
      user = User.new(id: 1)
      user.first_name = 'JaNe SmItH'

      expect(user.first_name).to eq('JaNe SmItH')
    end

    it 'handles nil values in writer' do
      user = User.new(id: 1, first_name: 'John')
      user.first_name = nil

      expect(user.first_name).to be_nil
    end

    it 'handles non-string values in writer' do
      user = User.new(id: 1)
      user.first_name = 123

      expect(user.first_name).to eq(123)
    end
  end
end
