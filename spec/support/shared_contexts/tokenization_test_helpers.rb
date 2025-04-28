# Define a shared context for tokenization test helpers
RSpec.shared_context "tokenization test helpers" do
  # Create a mock encryption service for testing
  let(:encryption_service) do
    instance_double(PiiTokenizer::EncryptionService).tap do |service|
      allow(PiiTokenizer).to receive(:encryption_service).and_return(service)
      
      # Default stub for encrypt_batch
      allow(service).to receive(:encrypt_batch) do |tokens_data|
        result = {}
        tokens_data.each do |data|
          key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
          result[key] = "token_for_#{data[:value]}"
        end
        result
      end
      
      # Default stub for decrypt_batch
      allow(service).to receive(:decrypt_batch) do |tokens|
        result = {}
        tokens = Array(tokens)
        
        tokens.each do |token|
          # Extract original value from token format "token_for_X"
          if token.to_s.start_with?("token_for_")
            original_value = token.to_s.sub("token_for_", "")
            result[token] = original_value
          end
        end
        
        result
      end
      
      # Default stub for search_tokens
      allow(service).to receive(:search_tokens) do |value|
        ["token_for_#{value}"]
      end
    end
  end
  
  # Helper method to stub encryption batch
  def stub_encrypt_batch
    allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
      result = {}
      tokens_data.each do |data|
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
        result[key] = "token_for_#{data[:value]}"
      end
      result
    end
  end
  
  # Helper method to set up a test user
  let(:user) do
    User.new(id: 1, first_name: 'John', last_name: 'Doe', email: 'john.doe@example.com')
  end
  
  # Helper method to reset test database before each test
  before do
    User.delete_all
    InternalUser.delete_all
    Contact.delete_all
  end
end 