# frozen_string_literal: true

module RubyLLM
  module MCP
    module Native
      module Transports
        module Support
          class HTTPClient
            CONNECTION_KEY = :ruby_llm_mcp_client_connection
            SECURITY_OPTIONS_KEY = :ruby_llm_mcp_http_security_options

            def self.security_options
              Thread.current[SECURITY_OPTIONS_KEY]
            end

            def self.security_options=(options)
              Thread.current[SECURITY_OPTIONS_KEY] = options
              Thread.current[CONNECTION_KEY] = nil
            end

            def self.secure(client, options = security_options)
              if options
                client.with(**options)
              else
                client
              end
            end

            def self.connection(options = security_options)
              return build_connection(options) if options

              Thread.current[CONNECTION_KEY] ||= build_connection(nil)
            end

            def self.build_connection(options)
              secure(HTTPX, options).with(
                pool_options: {
                  max_connections: RubyLLM::MCP.config.max_connections,
                  pool_timeout: RubyLLM::MCP.config.pool_timeout
                }
              )
            end
          end
        end
      end
    end
  end
end
