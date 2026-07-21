# frozen_string_literal: true

module RubyLLM
  module MCP
    module Adapters
      # Adapter backed exclusively by the official mcp gem. Native transports and
      # protocol behavior remain owned by RubyLLMAdapter.
      class MCPSdkAdapter < BaseAdapter
        SDK_REQUIREMENT = Gem::Requirement.new("~> 0.25")
        HTTP_TRANSPORTS = %i[http streamable streamable_http].freeze
        COLLECTION_METHODS = {
          tools: ["tools/list", "tools"],
          resources: ["resources/list", "resources"],
          resource_templates: ["resources/templates/list", "resourceTemplates"],
          prompts: ["prompts/list", "prompts"]
        }.freeze

        supports :tools, :resources, :prompts, :resource_templates, :completions
        supports_on(*HTTP_TRANSPORTS, features: %i[oauth sampling elicitation])
        supports_transport :stdio, *HTTP_TRANSPORTS

        attr_reader :transport_type, :config, :mcp_client

        def initialize(client, transport_type:, config: {})
          validate_transport!(transport_type)
          require_mcp_gem!
          super

          @mcp_client = nil
          @server_info = nil
          @cache_hints = {}
          @elicitation_enabled = MCP.config.elicitation.enabled?
        end

        def start
          return if alive?

          @mcp_client = ::MCP::Client.new(transport: build_transport)
          register_server_request_handlers
          connect_result = with_sdk_errors do
            @mcp_client.connect(
              client_info: { name: client.name, version: RubyLLM::MCP::VERSION },
              protocol_version: protocol_version,
              capabilities: client_capabilities
            )
          end
          @server_info = connect_result || @mcp_client.server_info
          unless @server_info.is_a?(Hash)
            raise Errors::TransportError.new(message: "Official MCP SDK connected without server information")
          end

          @capabilities = ServerCapabilities.new(@server_info.fetch("capabilities", {}))
        rescue StandardError
          stop
          raise
        end

        def stop
          @mcp_client&.transport&.close
        ensure
          @mcp_client = nil
          @server_info = nil
          @capabilities = nil
          @cache_hints = {}
        end

        def restart!
          stop
          start
        end

        def alive?
          !!@mcp_client&.connected?
        rescue StandardError
          false
        end

        def ping
          ensure_started
          with_sdk_errors { @mcp_client.ping == {} }
        rescue Errors::TransportError, Errors::SessionExpiredError
          false
        end

        def capabilities
          info = @server_info || @mcp_client&.server_info || {}
          @capabilities ||= ServerCapabilities.new(info["capabilities"] || {})
        end

        def client_capabilities
          capabilities = {}
          capabilities[:sampling] = sampling_capabilities if sampling_enabled?
          capabilities[:elicitation] = elicitation_capabilities if elicitation_enabled?

          extensions = build_client_extensions_capabilities(protocol_version: protocol_version)
          capabilities[:extensions] = extensions unless extensions.empty?
          capabilities
        end

        def supports_extension_negotiation?
          true
        end

        def extension_mode
          :full
        end

        def build_client_extensions_capabilities(protocol_version:)
          return {} unless Native::Protocol.extensions_supported?(protocol_version)

          Extensions::Registry.normalize_map(@config[:extensions]).transform_values { |value| value || {} }
        end

        def cache_hints
          @cache_hints.transform_values(&:dup).freeze
        end

        # Existing handler-class factories refer to adapter.native_client as
        # their response coordinator. During an SDK server request this is the
        # bridge for that request, never a RubyLLM native protocol client.
        def native_client
          Thread.current[:ruby_llm_mcp_sdk_bridge] || self
        end

        def tool_list(cursor: nil)
          paginated_list(:tools, cursor: cursor)
        end

        def execute_tool(name:, parameters:)
          ensure_started
          response = with_sdk_errors { @mcp_client.call_tool(name: name, arguments: parameters) }
          Result.new(response)
        end

        def resource_list(cursor: nil)
          paginated_list(:resources, cursor: cursor)
        end

        def resource_read(uri:)
          ensure_started
          response = sdk_request(method: "resources/read", params: { uri: uri })
          Result.new(response)
        end

        def prompt_list(cursor: nil)
          paginated_list(:prompts, cursor: cursor)
        end

        def execute_prompt(name:, arguments:)
          ensure_started
          response = sdk_request(
            method: "prompts/get",
            params: { name: name, arguments: arguments }
          )
          Result.new(response)
        end

        def resource_template_list(cursor: nil)
          paginated_list(:resource_templates, cursor: cursor)
        end

        def completion_resource(uri:, argument:, value:, context: nil)
          complete(ref: { type: "ref/resource", uri: uri }, argument: argument, value: value, context: context)
        end

        def completion_prompt(name:, argument:, value:, context: nil)
          complete(ref: { type: "ref/prompt", name: name }, argument: argument, value: value, context: context)
        end

        def set_elicitation_enabled(enabled:)
          @elicitation_enabled = enabled
        end

        def register_resource(resource)
          client.linked_resources << resource
        end

        private

        def ensure_started
          start unless alive?
        end

        def require_mcp_gem!
          require "mcp"
          return if SDK_REQUIREMENT.satisfied_by?(Gem::Version.new(::MCP::VERSION))

          raise Errors::AdapterConfigurationError.new(
            message: "The :mcp_sdk adapter requires mcp #{SDK_REQUIREMENT}; found #{::MCP::VERSION}."
          )
        rescue LoadError => e
          raise e unless e.path == "mcp"

          raise LoadError, <<~MSG
            The official MCP SDK is required to use the :mcp_sdk adapter.

            Add to your Gemfile:
              gem "mcp", "~> 0.25"

            For HTTP also add:
              gem "faraday", ">= 2"
              gem "event_stream_parser", ">= 1"
          MSG
        end

        def build_transport
          case @transport_type
          when :stdio
            build_stdio_transport
          when *HTTP_TRANSPORTS
            build_http_transport
          end
        end

        def build_stdio_transport
          options = {
            command: config_value(:command),
            args: config_value(:args) || [],
            env: config_value(:env),
            read_timeout: request_timeout_seconds
          }
          max_line_bytes = config_value(:max_line_bytes)
          options[:max_line_bytes] = max_line_bytes if max_line_bytes
          ::MCP::Client::Stdio.new(**options)
        end

        def build_http_transport
          options = {
            url: config_value(:url),
            headers: config_value(:headers) || {},
            oauth: sdk_oauth_provider
          }
          max_message_bytes = config_value(:max_message_bytes)
          options[:max_message_bytes] = max_message_bytes if max_message_bytes
          customizer = config_value(:faraday)

          ::MCP::Client::HTTP.new(**options) do |connection|
            connection.options.timeout = request_timeout_seconds
            connection.options.open_timeout = request_timeout_seconds
            customizer&.call(connection)
          end
        rescue LoadError => e
          raise LoadError,
                "#{e.message}\nFor mcp_sdk HTTP add faraday >= 2 and event_stream_parser >= 1 to your Gemfile."
        end

        def sdk_oauth_provider
          oauth = config_value(:oauth)
          provider = oauth.is_a?(Hash) ? (oauth[:provider] || oauth["provider"]) : oauth
          return if provider.nil?

          if defined?(Auth::OAuthProvider) && provider.is_a?(Auth::OAuthProvider)
            raise Errors::AdapterConfigurationError.new(
              message: "RubyLLM::MCP native OAuth providers cannot be used with :mcp_sdk. " \
                       "Pass an MCP::Client::OAuth provider via config: { oauth: provider }."
            )
          end

          provider
        end

        def register_server_request_handlers
          return unless HTTP_TRANSPORTS.include?(@transport_type)

          @mcp_client.on_sampling { |params| handle_sampling_request(params) } if sampling_enabled?
          @mcp_client.on_elicitation { |params| handle_elicitation_request(params) } if elicitation_enabled?
        end

        def handle_sampling_request(params)
          bridge = ServerRequestBridge.new(client, timeout: request_timeout_seconds)
          result = Result.new({ "id" => SecureRandom.uuid, "method" => "sampling/createMessage", "params" => params })
          bridge.with_current { Sample.new(result, bridge).execute }
          bridge.response!(wait: false)
        end

        def handle_elicitation_request(params)
          bridge = ServerRequestBridge.new(client, timeout: server_request_timeout_seconds)
          result = Result.new({ "id" => SecureRandom.uuid, "method" => "elicitation/create", "params" => params })
          elicitation = Elicitation.new(bridge, result)
          bridge.with_current { elicitation.execute }
          bridge.response!(wait: true, timeout_response: { "action" => "cancel" }) do
            elicitation.timeout!
            Handlers::ElicitationRegistry.remove(elicitation.id)
          end
        end

        def sampling_enabled?
          supports?(:sampling) && MCP.config.sampling.enabled?
        end

        def elicitation_enabled?
          supports?(:elicitation) && @elicitation_enabled
        end

        def sampling_capabilities
          value = {}
          value[:tools] = {} if MCP.config.sampling.tools
          value[:context] = {} if MCP.config.sampling.context
          value
        end

        def elicitation_capabilities
          value = {}
          value[:form] = {} if MCP.config.elicitation.form
          value[:url] = {} if MCP.config.elicitation.url
          value
        end

        def complete(ref:, argument:, value:, context:)
          ensure_started
          completion = with_sdk_errors do
            @mcp_client.complete(
              ref: ref,
              argument: { name: argument, value: value },
              context: context
            )
          end
          Result.new({ "result" => { "completion" => completion } })
        end

        def paginated_list(collection, cursor: nil)
          ensure_started
          method, result_key = COLLECTION_METHODS.fetch(collection)
          items = []
          pages = []
          seen = {}

          loop do
            response = sdk_request(method: method, params: cursor ? { cursor: cursor } : nil)
            result = response.fetch("result", {})
            items.concat(result[result_key] || [])
            pages << result
            next_cursor = result["nextCursor"]
            break if next_cursor.nil? || seen[next_cursor]

            seen[next_cursor] = true
            cursor = next_cursor
          end

          store_cache_hint(collection, pages)
          items
        end

        def store_cache_hint(collection, pages)
          ttls = pages.filter_map { |page| page["ttlMs"] }
          scopes = pages.filter_map { |page| page["cacheScope"] }
          @cache_hints[collection] = {
            ttl_ms: ttls.min,
            cache_scope: scopes.include?("private") ? "private" : scopes.first
          }.compact.freeze
        end

        def sdk_request(method:, params: nil)
          request = {
            jsonrpc: "2.0",
            id: SecureRandom.uuid,
            method: method
          }
          request[:params] = params if params

          response = with_sdk_errors { @mcp_client.transport.send_request(request: request) }
          if response.is_a?(Hash) && response["error"]
            error = response["error"]
            raise Errors::ResponseError.new(
              message: "Response error: #{error['message']}",
              error: error
            )
          end
          response
        end

        def with_sdk_errors
          yield
        rescue ::MCP::Client::ServerError => e
          raise Errors::ResponseError.new(
            message: "Response error: #{e.message}",
            error: { "code" => e.code, "message" => e.message, "data" => e.data }.compact
          )
        rescue ::MCP::Client::SessionExpiredError => e
          message = "MCP session expired; call restart! before retrying: #{e.message}"
          raise Errors::SessionExpiredError.new(message: message)
        rescue ::MCP::CancelledError => e
          raise Errors::RequestCancelled.new(message: e.message, request_id: e.request_id)
        rescue ::MCP::Client::InputRequiredError => e
          message = "The server requested multi-round-trip input, which is not supported " \
                    "on the stable 2025-11-25 integration: #{e.message}"
          raise Errors::UnsupportedFeature.new(
            message: message
          )
        rescue ::MCP::Client::RequestHandlerError, ::MCP::Client::ValidationError => e
          raise Errors::TransportError.new(message: e.message, error: e)
        end

        def protocol_version
          config_value(:protocol_version) || MCP.config.protocol_version
        end

        def request_timeout_seconds
          (config_value(:request_timeout) || 10_000).to_f / 1000
        end

        # Leave enough time for the SDK to serialize and send the server-request
        # response before the enclosing HTTP request reaches its own deadline.
        def server_request_timeout_seconds
          request_timeout_seconds * 0.8
        end

        def config_value(key)
          @config[key] || @config[key.to_s]
        end

        # Kept for compatibility with callers that normalized SDK model objects
        # through the adapter before 0.25. The 0.25 list path now preserves the
        # original wire hashes directly.
        def transform_tool(tool)
          return tool if tool.is_a?(Hash)

          {
            "name" => tool.name,
            "description" => tool.description,
            "inputSchema" => tool.input_schema,
            "outputSchema" => tool.output_schema,
            "_meta" => tool.respond_to?(:meta) ? tool.meta : tool["_meta"]
          }.compact
        end

        def transform_resource(resource)
          resource
        end

        def transform_prompt(prompt)
          prompt
        end

        def transform_resource_template(resource_template)
          resource_template
        end

        # Captures responses emitted by the existing Sample/Elicitation objects so
        # they can satisfy the official SDK's synchronous server-request contract.
        class ServerRequestBridge
          def initialize(client, timeout:)
            @client = client
            @timeout = timeout
            @mutex = Mutex.new
            @condition = ConditionVariable.new
            @response = nil
            @error = nil
          end

          def with_current
            previous = Thread.current[:ruby_llm_mcp_sdk_bridge]
            Thread.current[:ruby_llm_mcp_sdk_bridge] = self
            yield
          ensure
            Thread.current[:ruby_llm_mcp_sdk_bridge] = previous
          end

          def sampling_callback
            @client.on[:sampling]
          end

          def sampling_callback_enabled?
            @client.sampling_callback_enabled?
          end

          def elicitation_callback
            @client.on[:elicitation]
          end

          def register_in_flight_request(*)
            nil
          end

          def unregister_in_flight_request(*)
            nil
          end

          def sampling_create_message_response(id:, model:, message:, **_options)
            response = Native::Messages::Responses.sampling_create_message(id: id, model: model, message: message)
            resolve(response[:result])
          end

          def elicitation_response(id:, elicitation:)
            normalized = elicitation.transform_keys(&:to_sym)
            response = Native::Messages::Responses.elicitation(id: id, **normalized)
            resolve(response[:result])
          end

          def error_response(id:, message:, code: -1) # rubocop:disable Lint/UnusedMethodArgument
            @mutex.synchronize do
              @error ||= [message, code]
              @condition.broadcast
            end
          end

          def response!(wait:, timeout_response: nil)
            await_response if wait
            response, error = @mutex.synchronize { [@response, @error] }
            if error
              raise ::MCP::Client::ServerRequestError.new(error.first, code: error.last)
            end
            return response if response

            if wait && timeout_response
              yield if block_given?
              return timeout_response
            end

            raise ::MCP::Client::ServerRequestError.new("Client handler did not produce a response", code: -1)
          end

          private

          def resolve(response)
            @mutex.synchronize do
              @response = stringify_keys(response)
              @condition.broadcast
            end
          end

          def await_response
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
            @mutex.synchronize do
              until @response || @error
                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                break if remaining <= 0

                @condition.wait(@mutex, remaining)
              end
            end
          end

          def stringify_keys(value)
            case value
            when Hash
              value.to_h { |key, item| [key.to_s, stringify_keys(item)] }
            when Array
              value.map { |item| stringify_keys(item) }
            else
              value
            end
          end
        end
      end
    end
  end
end
