# frozen_string_literal: true

# Standard Libraries
require "cgi"
require "date"
require "erb"
require "json"
require "logger"
require "open3"
require "rbconfig"
require "securerandom"
require "socket"
require "timeout"
require "uri"
require "yaml"

# Gems
require "httpx"
require "json-schema"
require "ruby_llm"
require "zeitwerk"

require_relative "chat"

module RubyLLM
  module MCP
    module_function

    TOOLSET_OPTION_MAPPINGS = {
      from_clients: %i[clients client_names],
      include_tools: %i[include_tools include],
      exclude_tools: %i[exclude_tools exclude]
    }.freeze
    TOOLSET_OPTION_KEYS = TOOLSET_OPTION_MAPPINGS.values.flatten.freeze

    def clients(config = RubyLLM::MCP.config.mcp_configuration)
      if @clients.nil?
        @clients = {}
        config.map do |options|
          @clients[options[:name]] ||= Client.new(**options)
        end
      end
      @clients
    end

    def add_client(options)
      clients[options[:name]] ||= Client.new(**options)
    end

    def remove_client(name)
      client = clients.delete(name)
      client&.stop
      connection_mutex.synchronize { connection_leases.delete(name.to_s) }
      client
    end

    def client(...)
      Client.new(...)
    end

    # Ask the model for a response even when the chat already ends with an
    # assistant message. RubyLLM 2's Chat#complete returns that existing message
    # without calling the provider, but MCP prompts and sampling requests may
    # legitimately end with assistant text the model is expected to continue.
    # Chat#generate forces one generation and #complete then finishes any tool
    # cycle it started. RubyLLM 1 has no #generate and its #complete always
    # generates, so only #complete is called there.
    def generate_response(chat, &)
      if chat.respond_to?(:generate)
        chat.generate(&)
      end

      chat.complete(&)
    end

    def establish_connection(client_names: nil)
      selected_clients = select_clients(client_names)

      unless block_given?
        selected_clients.each_value(&:start)
        return selected_clients
      end

      acquire_connections(selected_clients)
      begin
        yield selected_clients
      ensure
        release_connections(selected_clients)
      end
    end

    def close_connection
      connection_mutex.synchronize do
        clients.each_value do |client|
          client.stop if client.alive?
        end
        connection_leases.clear
      end
    end

    def tools(blacklist: [], whitelist: [])
      tools = clients.values.map(&:tools)
                     .flatten
                     .reject { |tool| blacklist.include?(tool.name) }

      tools = tools.select { |tool| whitelist.include?(tool.name) } if whitelist.any?
      tools.uniq(&:name)
    end

    def toolset(name, options = nil)
      if block_given? && !options.nil?
        raise ArgumentError, "Provide either configuration options or a block, not both"
      end

      normalized_options = normalize_toolset_options(options) if options
      toolset_name = name.to_sym
      @toolsets ||= {}
      configured_toolset = (@toolsets[toolset_name] ||= Toolset.new(name: toolset_name))

      if block_given?
        yield configured_toolset
        return configured_toolset
      end

      return configured_toolset unless normalized_options

      apply_toolset_options(configured_toolset, normalized_options)
    end

    def toolsets
      configured_toolsets = @toolsets || {}
      configured_toolsets.dup
    end

    def mcp_configurations
      config.mcp_configuration.each_with_object({}) do |config, acc|
        acc[config[:name]] = config
      end
    end

    def configure
      yield config
    end

    def config
      @config ||= Configuration.new
    end

    alias configuration config
    module_function :configuration

    def logger
      config.logger
    end

    def apply_toolset_options(toolset, options)
      TOOLSET_OPTION_MAPPINGS.each do |method_name, keys|
        next unless keys.any? { |key| options.key?(key) }

        values = keys.flat_map { |key| Array(options[key]) }
        toolset.public_send(method_name, *values)
      end

      toolset
    end
    private_class_method :apply_toolset_options

    def normalize_toolset_options(options)
      normalized = options.dup.transform_keys(&:to_sym)
      unknown_keys = normalized.keys - TOOLSET_OPTION_KEYS
      return normalized if unknown_keys.empty?

      label = unknown_keys.one? ? "option" : "options"
      raise ArgumentError, "Unknown toolset #{label}: #{unknown_keys.join(', ')}"
    end
    private_class_method :normalize_toolset_options

    def select_clients(client_names)
      available_clients = clients.transform_keys(&:to_s)
      return available_clients if client_names.nil?

      requested_names = Array(client_names).flatten.compact.map(&:to_s).uniq
      missing_names = requested_names - available_clients.keys
      if missing_names.any?
        raise Errors::ConfigurationError.new(
          message: "Unknown MCP client name(s): #{missing_names.join(', ')}"
        )
      end

      available_clients.slice(*requested_names)
    end
    private_class_method :select_clients

    def acquire_connections(selected_clients)
      connection_mutex.synchronize do
        acquired_clients = []

        begin
          selected_clients.each do |name, client|
            start_connection(name, client)
            connection_leases[name] += 1
            acquired_clients << [name, client]
          end
        rescue StandardError
          release_connections_without_lock(acquired_clients.reverse)
          raise
        end
      end
    end
    private_class_method :acquire_connections

    def release_connections(selected_clients)
      connection_mutex.synchronize do
        release_connections_without_lock(selected_clients.to_a.reverse)
      end
    end
    private_class_method :release_connections

    def start_connection(name, client)
      return unless connection_leases[name].zero?

      client.start
    rescue StandardError
      client.stop if client.alive?
      raise
    end
    private_class_method :start_connection

    def release_connections_without_lock(selected_clients)
      selected_clients.each do |name, client|
        lease_count = connection_leases[name]
        next if lease_count.zero?

        if lease_count == 1
          connection_leases.delete(name)
          client.stop if client.alive?
        else
          connection_leases[name] = lease_count - 1
        end
      end
    end
    private_class_method :release_connections_without_lock

    def connection_leases
      @connection_leases ||= Hash.new(0)
    end
    private_class_method :connection_leases

    def connection_mutex
      @connection_mutex ||= Mutex.new
    end
    private_class_method :connection_mutex
  end
end

loader = Zeitwerk::Loader.for_gem_extension(RubyLLM)

loader.ignore("#{__dir__}/mcp/railtie.rb")

loader.inflector.inflect("mcp" => "MCP")
loader.inflector.inflect("sse" => "SSE")
loader.inflector.inflect("openai" => "OpenAI")
loader.inflector.inflect("streamable_http" => "StreamableHTTP")
loader.inflector.inflect("http_client" => "HTTPClient")
loader.inflector.inflect("http_server" => "HttpServer")

loader.inflector.inflect("ruby_llm_adapter" => "RubyLLMAdapter")
loader.inflector.inflect("mcp_sdk_adapter" => "MCPSdkAdapter")
loader.inflector.inflect("mcp_transports" => "MCPTransports")

loader.inflector.inflect("oauth_provider" => "OAuthProvider")
loader.inflector.inflect("browser_oauth_provider" => "BrowserOAuthProvider")

loader.setup

if defined?(Rails::Railtie)
  require_relative "mcp/railtie"
end
