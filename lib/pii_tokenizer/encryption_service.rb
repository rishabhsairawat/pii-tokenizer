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
    #   - :pii_type => type of PII data (e.g., EMAIL, PHONE, etc.)
    #
    # @return [Hash] Mapping of request keys to encrypted values
    def encrypt_batch(tokens_data)
      return {} if tokens_data.empty?

      request_data = tokens_data.map do |token_data|
        {
          entity_type: token_data[:entity_type],
          entity_id: token_data[:entity_id],
          pii_type: token_data[:pii_type], # Use the provided pii_type
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
    # @param tokens_data [Array<String>, Array<Hash>, String] Tokens to decrypt
    #   If Array<Hash>, each hash should have:
    #   - :token => the encrypted token to decrypt
    #   - :entity_id => the entity ID for this value
    #   - :entity_type => the entity type
    #   - :pii_type => type of PII data
    #
    # @return [Hash] Mapping of tokens to decrypted values, or entity keys to values if hashes provided
    def decrypt_batch(tokens_data)
      return {} if tokens_data.nil? || (tokens_data.is_a?(Array) && tokens_data.empty?)

      # Handle different input formats
      if tokens_data.is_a?(Array) && tokens_data.first.is_a?(Hash)
        # Legacy format with array of hashes with token, entity_id, etc.
        tokens = tokens_data.map { |td| td[:token] }

        response = api_client.get('/api/v1/tokens/decrypt', tokens: tokens)

        if response.success?
          token_to_value = parse_token_to_value(response.body)

          # Map back to entity keys for compatibility with existing code
          result = {}
          tokens_data.each do |td|
            if token_to_value.key?(td[:token])
              key = "#{td[:entity_type].upcase}:#{td[:entity_id]}:#{td[:pii_type]}"
              result[key] = token_to_value[td[:token]]
            end
          end

          result
        else
          handle_error_response(response)
        end
      else
        # New format with just tokens
        tokens = tokens_data.is_a?(Array) ? tokens_data : [tokens_data]

        response = api_client.get('/api/v1/tokens/decrypt', tokens: tokens)

        if response.success?
          parse_token_to_value(response.body)
        else
          handle_error_response(response)
        end
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

    # Parse the decrypt response to create a mapping of token to decrypted value
    def parse_token_to_value(response_body)
      result = {}
      response_data = JSON.parse(response_body)

      response_data['data'].each do |item|
        result[item['token']] = item['decrypted_value']
      end

      result
    end

    def generate_key(token_data)
      "#{token_data['entity_type'].upcase}:#{token_data['entity_id']}:#{token_data['pii_type']}"
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
