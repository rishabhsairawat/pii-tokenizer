require 'spec_helper'

RSpec.describe 'PiiTokenizer::EntityTypes' do
  it 'defines supported entity types' do
    expect(PiiTokenizer::EntityTypes::USER_UUID).to eq('USER_UUID')
    expect(PiiTokenizer::EntityTypes::PROFILE_UUID).to eq('PROFILE_UUID')
  end

  it 'provides a list of all supported entity types' do
    expect(PiiTokenizer::EntityTypes.all).to include('USER_UUID', 'PROFILE_UUID')
    expect(PiiTokenizer::EntityTypes.all.size).to eq(2)
  end

  it 'can check if an entity type is supported' do
    expect(PiiTokenizer::EntityTypes.supported?('USER_UUID')).to be true
    expect(PiiTokenizer::EntityTypes.supported?('PROFILE_UUID')).to be true
    expect(PiiTokenizer::EntityTypes.supported?('UNSUPPORTED_TYPE')).to be false
  end

  it 'validates entity types during configuration' do
    expect do
      class TestInvalidEntity < ActiveRecord::Base
        self.table_name = 'users'
        include PiiTokenizer::Tokenizable

        tokenize_pii fields: { first_name: PiiTokenizer::PiiTypes::NAME },
                     entity_type: 'invalid_entity_type',
                     entity_id: ->(user) { "user_#{user.id}" }
      end
    end.to raise_error(ArgumentError, /Invalid entity type: invalid_entity_type/)
  end

  it 'accepts supported entity types during configuration' do
    expect do
      class TestValidEntity < ActiveRecord::Base
        self.table_name = 'users'
        include PiiTokenizer::Tokenizable

        tokenize_pii fields: { first_name: PiiTokenizer::PiiTypes::NAME },
                     entity_type: PiiTokenizer::EntityTypes::USER_UUID,
                     entity_id: ->(user) { "user_#{user.id}" }
      end
    end.not_to raise_error
  end

  it 'allows proc-based entity types without validation' do
    expect do
      class TestProcEntity < ActiveRecord::Base
        self.table_name = 'users'
        include PiiTokenizer::Tokenizable

        tokenize_pii fields: { first_name: PiiTokenizer::PiiTypes::NAME },
                     entity_type: ->(record) { record.respond_to?(:role) ? 'ADMIN' : 'USER' },
                     entity_id: ->(user) { "user_#{user.id}" }
      end
    end.not_to raise_error
  end
end
