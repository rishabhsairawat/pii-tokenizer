# Define a shared context for tests that need tokenizable models
RSpec.shared_context "with tokenizable models" do
  # Reset tokenizable models before each test
  before do
    User.delete_all
    InternalUser.delete_all
    Contact.delete_all
    
    # Configure User model
    User.tokenize_pii(
      fields: {
        first_name: 'FIRST_NAME',
        last_name: 'LAST_NAME',
        email: 'EMAIL'
      },
      entity_type: 'user_uuid',
      entity_id: ->(record) { "#{record.id}" },
      dual_write: false,
      read_from_token: true
    )
    
    # Configure InternalUser model
    InternalUser.tokenize_pii(
      fields: %i[first_name last_name],
      entity_type: 'internal_staff', 
      entity_id: ->(record) { "InternalUser_#{record.id}_#{record.role}" },
      dual_write: false,
      read_from_token: true
    )
    
    # Configure Contact model
    Contact.tokenize_pii(
      fields: {
        full_name: 'NAME',
        phone_number: 'PHONE',
        email_address: 'EMAIL'
      },
      entity_type: 'contact',
      entity_id: ->(record) { "Contact_#{record.id}" },
      dual_write: false,
      read_from_token: true
    )
  end
  
  # Helper method to create a test user
  let(:user) { User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com') }
  
  # Helper method to create a test internal user
  let(:internal_user) { InternalUser.new(id: 1, first_name: 'Jane', last_name: 'Smith', role: 'admin') }
  
  # Helper method to create a test contact
  let(:contact) { Contact.new(id: 1, full_name: 'Alice Brown', phone_number: '555-1234', email_address: 'alice@example.com') }
end 