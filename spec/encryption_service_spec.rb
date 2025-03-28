require "spec_helper"
require "json"

RSpec.describe PiiTokenizer::EncryptionService do
  let(:configuration) { PiiTokenizer::Configuration.new }
  let(:service) { PiiTokenizer::EncryptionService.new(configuration) }

  before do
    configuration.encryption_service_url = "https://encryption-service.example.com"
    configuration.batch_size = 10
  end

  describe "#encrypt_batch" do
    it "sends a properly formatted request to the encryption service" do
      tokens_data = [
        { value: "John", entity_id: "User_1", entity_type: "customer", field_name: "first_name" },
        { value: "Doe", entity_id: "User_1", entity_type: "customer", field_name: "last_name" }
      ]

      # Mock the API response
      api_response = double("Faraday::Response", 
        success?: true, 
        body: {
          tokens: [
            { token: "encrypted_john" },
            { token: "encrypted_doe" }
          ]
        }.to_json
      )

      # Expect a POST request to the encryption service with the correct body
      expect_any_instance_of(Faraday::Connection).to receive(:post).with('/encrypt_batch') do |_, &block|
        req = double("request")
        expect(req).to receive(:body=) do |body_json|
          body = JSON.parse(body_json)
          expect(body["tokens"]).to contain_exactly(
            { "value" => "John", "entity_id" => "User_1", "entity_type" => "customer", "field_name" => "first_name" },
            { "value" => "Doe", "entity_id" => "User_1", "entity_type" => "customer", "field_name" => "last_name" }
          )
        end
        expect(req).to receive(:headers).and_return({})
        block.call(req)
        api_response
      end

      # Call the method and check the result
      result = service.encrypt_batch(tokens_data)
      
      expect(result).to eq({
        "customer:User_1:first_name" => "encrypted_john",
        "customer:User_1:last_name" => "encrypted_doe"
      })
    end

    it "returns an empty hash when given an empty input" do
      expect(service.encrypt_batch([])).to eq({})
    end

    it "raises an error when the API returns an error" do
      tokens_data = [
        { value: "John", entity_id: "User_1", entity_type: "customer", field_name: "first_name" }
      ]

      # Mock an error response
      api_response = double("Faraday::Response", 
        success?: false, 
        status: 401,
        body: { error: "Unauthorized" }.to_json
      )

      allow_any_instance_of(Faraday::Connection).to receive(:post).and_return(api_response)

      expect { service.encrypt_batch(tokens_data) }.to raise_error(/Encryption service error/)
    end
  end

  describe "#decrypt_batch" do
    it "sends a properly formatted request to the encryption service" do
      tokens_data = [
        { token: "encrypted_john", entity_id: "User_1", entity_type: "customer", field_name: "first_name" },
        { token: "encrypted_doe", entity_id: "User_1", entity_type: "customer", field_name: "last_name" }
      ]

      # Mock the API response
      api_response = double("Faraday::Response", 
        success?: true, 
        body: {
          tokens: [
            { value: "John" },
            { value: "Doe" }
          ]
        }.to_json
      )

      # Expect a POST request to the encryption service with the correct body
      expect_any_instance_of(Faraday::Connection).to receive(:post).with('/decrypt_batch') do |_, &block|
        req = double("request")
        expect(req).to receive(:body=) do |body_json|
          body = JSON.parse(body_json)
          expect(body["tokens"]).to contain_exactly(
            { "token" => "encrypted_john", "entity_id" => "User_1", "entity_type" => "customer", "field_name" => "first_name" },
            { "token" => "encrypted_doe", "entity_id" => "User_1", "entity_type" => "customer", "field_name" => "last_name" }
          )
        end
        expect(req).to receive(:headers).and_return({})
        block.call(req)
        api_response
      end

      # Call the method and check the result
      result = service.decrypt_batch(tokens_data)
      
      expect(result).to eq({
        "customer:User_1:first_name" => "John",
        "customer:User_1:last_name" => "Doe"
      })
    end

    it "returns an empty hash when given an empty input" do
      expect(service.decrypt_batch([])).to eq({})
    end
  end
end 