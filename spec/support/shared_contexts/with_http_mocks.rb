# Define a shared context for tests that need HTTP mocks
RSpec.shared_context "with http mocks" do
  before do
    # Stub HTTP requests to the encryption service
    WebMock.disable_net_connect!
    
    # Stub the encryption batch endpoint
    stub_request(:post, "http://localhost:8000/api/v1/tokens/bulk")
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: lambda { |request|
          data = JSON.parse(request.body)
          response_data = data.map do |item|
            {
              token: "token_for_#{item['pii_field']}",
              entity_type: item['entity_type'],
              entity_id: item['entity_id'],
              pii_type: item['pii_type'],
              pii_field: item['pii_field'],
              created_at: Time.now.iso8601
            }
          end
          { data: response_data }.to_json
        }
      )
    
    # Stub the decryption endpoint
    stub_request(:get, /http:\/\/localhost:8000\/api\/v1\/tokens\/decrypt/)
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: lambda { |request|
          tokens = CGI.parse(request.uri.query)['tokens[]']
          response_data = tokens.map do |token|
            # Extract original value from token format "token_for_X"
            original_value = token.start_with?("token_for_") ? token.sub("token_for_", "") : "unknown"
            {
              token: token,
              decrypted_value: original_value
            }
          end
          { data: response_data }.to_json
        }
      )
    
    # Stub the search endpoint
    stub_request(:post, "http://localhost:8000/api/v1/tokens/search")
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: lambda { |request|
          data = JSON.parse(request.body)
          pii_field = data['pii_field']
          response_data = [
            {
              token: "token_for_#{pii_field}",
              decrypted_value: pii_field
            }
          ]
          { data: response_data }.to_json
        }
      )
  end
  
  after do
    WebMock.allow_net_connect!
  end
end 