require 'faraday'
require 'json'
require 'logger'

module PiiTokenizer
  # Service class responsible for interacting with the external encryption service
  # Handles encrypting and decrypting PII data through HTTP requests
  class EncryptionService
    # Initialize a new encryption service
    #
    # @param configuration [PiiTokenizer::Configuration] Configuration object containing settings
    # @raise [ArgumentError] If configuration is nil or encryption_service_url is not set
    def initialize(configuration)
      raise ArgumentError, 'Configuration must not be nil' if configuration.nil?
      raise ArgumentError, 'Encryption service URL must be configured' if configuration.encryption_service_url.nil?

      @configuration = configuration
      @logger = configuration.logger || Logger.new(STDOUT)
      @logger.level = configuration.log_level || Logger::INFO if @logger.respond_to?(:level=)

      # Only set formatter if this is our own logger instance
      if configuration.logger.nil? && @logger.respond_to?(:formatter=)
        @logger.formatter = proc do |severity, datetime, _progname, msg|
          "[#{datetime}] #{severity} -- PiiTokenizer: #{msg}\n"
        end
      end
    end

    # Encrypt multiple values in a batch
    #
    # @param tokens_data [Array<Hash>] Array of data to encrypt
    #   Each hash should have the keys:
    #   - :value [String] The value to encrypt
    #   - :entity_id [String] The entity ID for this value
    #   - :entity_type [String] The entity type (customer, employee, etc.)
    #   - :field_name [String] Name of the field being encrypted
    #   - :pii_type [String] Type of PII data (e.g., EMAIL, PHONE, etc.)
    #
    # @return [Hash<String, String>] Mapping of request keys to encrypted token values
    # @raise [RuntimeError] If the encryption service returns an error
    # @example Encrypt user data
    #   tokens_data = [
    #     {value: 'John Smith', entity_id: 'user_1', entity_type: 'user_uuid', field_name: 'name', pii_type: 'NAME'},
    #     {value: 'john@example.com', entity_id: 'user_1', entity_type: 'user_uuid', field_name: 'email', pii_type: 'EMAIL'}
    #   ]
    #   result = service.encrypt_batch(tokens_data)
    #   # => {"CUSTOMER:user_1:NAME" => "encrypted_token_1", "CUSTOMER:user_1:EMAIL" => "encrypted_token_2"}
    def encrypt_batch(tokens_data)
      return {} if tokens_data.nil? || tokens_data.empty?

      request_data = tokens_data.map do |token_data|
        {
          entity_type: token_data[:entity_type],
          entity_id: token_data[:entity_id],
          pii_type: token_data[:pii_type], # Use the provided pii_type
          pii_field: token_data[:value]
        }
      end

      log_request('POST', '/api/v1/tokens/bulk', request_data)

      begin
        response = api_client.post('/api/v1/tokens/bulk') do |req|
          req.body = request_data.to_json
          req.headers['Content-Type'] = 'application/json'
        end

        log_response(response)

        if response.success?
          parse_encrypt_response(response.body)
        else
          handle_error_response(response)
        end
      rescue Faraday::Error => e
        error_message = "Failed to connect to encryption service: #{e.message}"
        @logger.error(error_message)
        raise error_message
      end
    end

    # Decrypt multiple tokens in a batch
    #
    # @param tokens_data [Array<String>, Array<Hash>, String, nil] Tokens to decrypt
    #   Can be:
    #   - A single token string
    #   - An array of token strings
    #   - An array of hashes with :token, :entity_id, :entity_type, and :pii_type keys (legacy format)
    #   - nil (returns empty hash)
    #
    # @return [Hash<String, String>] Mapping of tokens to decrypted values, or entity keys to values if hashes provided
    # @raise [RuntimeError] If the decryption service returns an error
    # @example Decrypt tokens
    #   tokens = ['encrypted_token_1', 'encrypted_token_2']
    #   result = service.decrypt_batch(tokens)
    #   # => {"encrypted_token_1" => "John Smith", "encrypted_token_2" => "john@example.com"}
    def decrypt_batch(tokens_data)
      return {} if tokens_data.nil? || (tokens_data.is_a?(Array) && tokens_data.empty?)

      # Handle different input formats
      if tokens_data.is_a?(Array) && tokens_data.first.is_a?(Hash)
        # Legacy format with array of hashes with token, entity_id, etc.
        tokens = tokens_data.map { |td| td[:token] }

        log_request('GET', '/api/v1/tokens/decrypt', { tokens: tokens })

        begin
          response = api_client.get('/api/v1/tokens/decrypt', tokens: tokens)

          log_response(response)

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
        rescue Faraday::Error => e
          error_message = "Failed to connect to encryption service: #{e.message}"
          @logger.error(error_message)
          raise error_message
        end
      else
        # New format with just tokens
        tokens = tokens_data.is_a?(Array) ? tokens_data : [tokens_data]

        log_request('GET', '/api/v1/tokens/decrypt', { tokens: tokens })

        begin
          response = api_client.get('/api/v1/tokens/decrypt', tokens: tokens)

          log_response(response)

          if response.success?
            parse_token_to_value(response.body)
          else
            handle_error_response(response)
          end
        rescue Faraday::Error => e
          error_message = "Failed to connect to encryption service: #{e.message}"
          @logger.error(error_message)
          raise error_message
        end
      end
    end

    # Search for tokens matching a specific PII value
    #
    # @param pii_value [String] The PII value to search for
    # @return [Array<String>] Array of matching token values
    # @raise [RuntimeError] If the search service returns an error
    # @example Search for tokens by email
    #   tokens = service.search_tokens('john.doe@example.com')
    #   # => ['01JR638FS1569SX949M6WMKBCS']
    def search_tokens(pii_value)
      return [] if pii_value.nil? || (pii_value.respond_to?(:empty?) && pii_value.empty?)

      request_data = { pii_field: pii_value }
      log_request('POST', '/api/v1/tokens/search', request_data)

      begin
        response = api_client.post('/api/v1/tokens/search') do |req|
          req.body = request_data.to_json
          req.headers['Content-Type'] = 'application/json'
        end

        log_response(response)

        if response.success?
          parse_search_response(response.body)
        else
          handle_error_response(response)
        end
      rescue Faraday::Error => e
        error_message = "Failed to connect to encryption service: #{e.message}"
        @logger.error(error_message)
        raise error_message
      end
    end

    private

    # Log the details of an outgoing request
    # @param method [String] HTTP method (GET, POST, etc.)
    # @param path [String] API endpoint path
    # @param data [Hash, Array] Request payload
    def log_request(method, path, data)
      # Sanitize sensitive data for logging
      safe_data = sanitize_data_for_logging(data)
      @logger.info("REQUEST: #{method} #{@configuration.encryption_service_url}#{path} - Payload: #{safe_data.to_json}")
    end

    # Log the details of an incoming response
    # @param response [Faraday::Response] The HTTP response object
    def log_response(response)
      status = response.status
      safe_body = sanitize_response_for_logging(response.body)
      @logger.info("RESPONSE: HTTP #{status} - Body: #{safe_body}")
    end

    # Redact sensitive fields for logging
    # @param data [Hash, Array, Object] Data to sanitize
    # @return [Hash, Array, Object] Sanitized data with sensitive fields redacted
    def sanitize_data_for_logging(data)
      if data.is_a?(Array)
        data.map { |item| sanitize_data_for_logging(item) }
      elsif data.is_a?(Hash)
        sanitized = {}
        data.each do |k, v|
          sanitized[k] = if k.to_s == 'pii_field' || k.to_s == 'value'
                           'REDACTED'
                         else
                           v
                         end
        end
        sanitized
      else
        data
      end
    end

    # Redact sensitive fields from response bodies
    # @param body [String] Response body JSON string
    # @return [String] Sanitized JSON with sensitive fields redacted
    def sanitize_response_for_logging(body)
      return body unless body.is_a?(String) && !body.empty?

      begin
        data = JSON.parse(body)
        if data.key?('data') && data['data'].is_a?(Array)
          data['data'].each do |item|
            item['decrypted_value'] = 'REDACTED' if item.key?('decrypted_value')
            item['pii_field'] = 'REDACTED' if item.key?('pii_field')
          end
        end
        data.to_json
      rescue JSON::ParserError
        'Non-JSON response'
      end
    end

    # Create or get a Faraday HTTP client for the configured service
    # @return [Faraday::Connection] The HTTP client
    def api_client
      @api_client ||= Faraday.new(url: @configuration.encryption_service_url) do |conn|
        conn.adapter Faraday.default_adapter
        conn.options.timeout = 10 # 10 second timeout
        conn.options.open_timeout = 5 # 5 second open timeout
      end
    end

    # Parse the encryption response into a key-token mapping
    # @param response_body [String] JSON response body
    # @return [Hash<String, String>] Mapping of keys to tokens
    # @raise [JSON::ParserError] If response is not valid JSON
    def parse_encrypt_response(response_body)
      result = {}
      response_data = JSON.parse(response_body)

      response_data['data'].each do |token_data|
        key = generate_key(token_data)
        result[key] = token_data['token']
      end

      result
    end

    # Parse the decrypt response into a token-value mapping
    # @param response_body [String] JSON response body
    # @return [Hash<String, String>] Mapping of tokens to values
    # @raise [JSON::ParserError] If response is not valid JSON
    def parse_token_to_value(response_body)
      result = {}
      response_data = JSON.parse(response_body)

      response_data['data'].each do |item|
        result[item['token']] = item['decrypted_value']
      end

      result
    end

    # Parse the search tokens response and extract the tokens
    # @param response_body [String] JSON response body
    # @return [Array<String>] Array of matching tokens
    # @raise [JSON::ParserError] If response is not valid JSON
    def parse_search_response(response_body)
      response_data = JSON.parse(response_body)
      response_data['data'].map { |item| item['token'] }
    end

    # Generate a consistent key for token data
    # @param token_data [Hash] Token data with entity_type, entity_id, pii_type and pii_field
    # @return [String] Formatted key string
    def generate_key(token_data)
      "#{token_data['entity_type'].upcase}:#{token_data['entity_id']}:#{token_data['pii_type']}:#{token_data['pii_field']}"
    end

    # Handle error responses from the API
    # @param response [Faraday::Response] The HTTP response
    # @raise [RuntimeError] Always raised with error details
    def handle_error_response(response)
      error_message = "Encryption service error (HTTP #{response.status}): "

      begin
        error_data = JSON.parse(response.body)
        error_message += error_data['error'] || response.body
      rescue JSON::ParserError
        error_message += response.body
      end

      @logger.error(error_message)
      raise error_message
    end
  end
end
