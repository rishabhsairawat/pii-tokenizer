require 'faraday'
require 'json'

module PiiTokenizer
  class EncryptionService
    def initialize(configuration)
      @configuration = configuration
    end

    # Encrypt multiple values in a batch
    # 
    # @param tokens_data [Array<Hash>] Array of data to encrypt
    #   Each hash should have the keys:
    #   - :value => the value to encrypt
    #   - :entity_id => the entity ID for this value
    #   - :entity_type => the entity type
    #   - :field_name => name of the field being encrypted
    # 
    # @return [Hash] Mapping of request keys to encrypted values
    def encrypt_batch(tokens_data)
      return {} if tokens_data.empty?

      request_data = tokens_data.map do |token_data|
        {
          entity_type: token_data[:entity_type],
          entity_id: token_data[:entity_id],
          pii_type: token_data[:field_name].upcase, # Assuming pii_type is the field name in uppercase
          pii_field: token_data[:value]
        }
      end

      response = api_client.post('/api/v1/tokens/bulk') do |req|
        req.body = request_data.to_json
        req.headers['Content-Type'] = 'application/json'
      end

      if response.success?
        parse_encrypt_response(response.body)
      else
        handle_error_response(response)
      end
    end

    # Decrypt multiple tokens in a batch
    # 
    # @param tokens_data [Array<Hash>] Array of data to decrypt
    #   Each hash should have the keys:
    #   - :token => the encrypted token to decrypt
    #   - :entity_id => the entity ID for this value
    #   - :entity_type => the entity type
    #   - :field_name => name of the field being encrypted
    # 
    # @return [Hash] Mapping of token keys to decrypted values
    def decrypt_batch(tokens_data)
      return {} if tokens_data.empty?

      response = api_client.get('/api/v1/tokens/decrypt', { params: { tokens: tokens_data } })

      if response.success?
        parse_decrypt_response(response.body)
      else
        handle_error_response(response)
      end
    end

    private

    def api_client
      @api_client ||= Faraday.new(url: @configuration.encryption_service_url) do |conn|
        conn.adapter Faraday.default_adapter
      end
    end

    def parse_encrypt_response(response_body)
      result = {}
      response_data = JSON.parse(response_body)

      response_data['data'].each do |token_data|
        key = generate_key(token_data)
        result[key] = token_data['token']
      end

      result
    end

    def parse_decrypt_response(response_body)
      result = {}
      response_data = JSON.parse(response_body)

      response_data['data'].each do |token_data|
        result[token_data['token']] = token_data['decrypted_value']
      end

      result
    end

    def generate_key(token_data)
      "#{token_data['entity_type']}:#{token_data['entity_id']}:#{token_data['pii_type']}"
    end

    def handle_error_response(response)
      error_message = "Encryption service error (HTTP #{response.status}): "
      
      begin
        error_data = JSON.parse(response.body)
        error_message += error_data['error'] || response.body
      rescue JSON::ParserError
        error_message += response.body
      end
      
      raise error_message
    end
  end
end 