# Shared contexts and test helpers for PiiTokenizer
# This file provides standardized test utilities to ensure consistency across specs

# Shared context for encryption service testing
RSpec.shared_context "with encryption service" do
  let(:encryption_service) { instance_double(PiiTokenizer::EncryptionService) }
  let(:encryption_url) { 'https://encryption-service.example.com' }
  
  # Set up standard mocks for the encryption service
  before do
    allow(PiiTokenizer).to receive(:encryption_service).and_return(encryption_service)
    
    # Standard stub for encrypt_batch
    allow(encryption_service).to receive(:encrypt_batch) do |tokens_data|
      result = {}
      tokens_data.each do |data|
        next if data[:value].nil? || (data[:value].respond_to?(:blank?) && data[:value].blank?)
        key = "#{data[:entity_type].upcase}:#{data[:entity_id]}:#{data[:pii_type]}:#{data[:value]}"
        result[key] = "token_for_#{data[:value]}"
      end
      result
    end
    
    # Standard stub for decrypt_batch
    allow(encryption_service).to receive(:decrypt_batch) do |tokens|
      result = {}
      tokens.each do |token|
        # Extract the value from the token format "token_for_VALUE"
        if token.to_s.start_with?("token_for_")
          original_value = token.to_s.sub("token_for_", "")
          result[token] = original_value
        end
      end
      result
    end
    
    # Standard stub for search_tokens
    allow(encryption_service).to receive(:search_tokens) do |value|
      ["token_for_#{value}"]
    end
  end
end

# Shared context for model testing
RSpec.shared_context "with tokenizable models" do
  # Helper to create a user with token values (simulating a saved record)
  def create_persisted_user_with_tokens(attributes = {})
    default_attrs = { 
      id: 1, 
      first_name: 'John', 
      last_name: 'Doe', 
      email: 'john.doe@example.com' 
    }
    user = User.new(default_attrs.merge(attributes))
    
    # Set token values
    user.safe_write_attribute(:first_name_token, "token_for_#{user.first_name}")
    user.safe_write_attribute(:last_name_token, "token_for_#{user.last_name}")  
    user.safe_write_attribute(:email_token, "token_for_#{user.email}")
    
    # Mark as persisted
    allow(user).to receive(:new_record?).and_return(false)
    allow(user).to receive(:persisted?).and_return(true)
    allow(user).to receive(:changes).and_return({})
    
    # Clear instance variables that would trigger encryption
    user.instance_variable_set(:@field_decryption_cache, {})
    
    # Remove instance variables set during initialization
    clear_original_instance_variables(user)
    
    user
  end
  
  # Helper to clear instance variables that would trigger encryption
  def clear_original_instance_variables(user)
    User.tokenized_fields.each do |field|
      variable_name = "@original_#{field}"
      user.remove_instance_variable(variable_name) if user.instance_variable_defined?(variable_name)
    end
  end
  
  # Helper to test with dual_write settings
  def with_dual_write_setting(model_class, value)
    original_setting = model_class.dual_write_enabled
    model_class.dual_write_enabled = value
    begin
      yield
    ensure
      model_class.dual_write_enabled = original_setting
    end
  end
  
  # Helper to test with read_from_token setting
  def with_read_from_token_setting(model_class, value)
    original_setting = model_class.read_from_token_column
    model_class.read_from_token_column = value
    begin
      yield
    ensure
      model_class.read_from_token_column = original_setting
    end
  end
  
  # Helper to restore a model to its original configuration
  def with_model_config(model_class, options = {})
    # Save original settings
    original_dual_write = model_class.dual_write_enabled
    original_read_from_token = model_class.read_from_token_column
    
    # Apply new settings if provided
    model_class.dual_write_enabled = options[:dual_write] if options.key?(:dual_write)
    model_class.read_from_token_column = options[:read_from_token] if options.key?(:read_from_token)
    
    begin
      yield
    ensure
      # Restore original settings
      model_class.dual_write_enabled = original_dual_write
      model_class.read_from_token_column = original_read_from_token
    end
  end
end

# Shared context for HTTP request testing
RSpec.shared_context "with http mocks" do
  # Helper to stub a successful encrypt request
  def stub_encrypt_request(url, tokens_data, response_tokens)
    stub_request(:post, "#{url}/api/v1/tokens/bulk")
      .with(body: tokens_data.to_json)
      .to_return(
        status: 200,
        body: { data: response_tokens }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end
  
  # Helper to stub a successful decrypt request
  def stub_decrypt_request(url, tokens, decrypted_values)
    # Create the query string for tokens
    query = tokens.map { |t| "tokens[]=#{t}" }.join('&')
    
    # Create the response data
    response_data = tokens.zip(decrypted_values).map do |token, value|
      { token: token, decrypted_value: value }
    end
    
    stub_request(:get, "#{url}/api/v1/tokens/decrypt?#{query}")
      .to_return(
        status: 200,
        body: { data: response_data }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end
  
  # Helper to stub an error response
  def stub_error_response(url, method, path, status_code, error_message)
    stub_request(method, "#{url}#{path}")
      .to_return(
        status: status_code,
        body: { error: error_message }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end
end 