# frozen_string_literal: true

module RubyLLM
  module MCP
    class Toolset
      attr_reader :name, :client_names

      def initialize(name:)
        @name = name.to_sym
        @client_names = [].freeze
        @include_tool_names = []
        @exclude_tool_names = []
        @exclusive = false
      end

      def from_clients(*names)
        @client_names = normalize_names(names).freeze
        self
      end

      alias clients from_clients

      def include_tools(*names)
        @include_tool_names = normalize_names(names)
        @exclusive = true
        self
      end

      def exclude_tools(*names)
        @exclude_tool_names = normalize_names(names)
        self
      end

      def tools(clients:)
        available_clients = normalize_clients(clients)
        resolved_tools = select_clients(available_clients).flat_map(&:tools)
        resolved_tools = resolve_include_tools(resolved_tools)
        resolved_tools = resolve_exclude_tools(resolved_tools)
        resolved_tools.uniq(&:name)
      end

      def with_tools
        raise ArgumentError, "A block is required" unless block_given?

        RubyLLM::MCP.establish_connection(client_names: connection_client_names) do |clients_map|
          yield tools(clients: clients_map)
        end
      end

      private

      def normalize_clients(clients)
        clients.is_a?(Hash) ? clients.values : Array(clients)
      end

      def connection_client_names
        @client_names.empty? ? nil : @client_names
      end

      def select_clients(clients)
        return clients if @client_names.empty?

        clients_by_name = clients.each_with_object({}) do |client, acc|
          acc[client.name.to_s] = client
        end
        ensure_configured_clients_exist!(clients_by_name)
        clients_by_name.values_at(*@client_names)
      end

      def ensure_configured_clients_exist!(clients_by_name)
        missing_names = @client_names - clients_by_name.keys
        return if missing_names.empty?

        raise Errors::ConfigurationError.new(
          message: "Unknown MCP client name(s): #{missing_names.join(', ')}"
        )
      end

      def resolve_include_tools(resolved_tools)
        return resolved_tools unless @exclusive && @include_tool_names.any?

        resolved_tools.select { |tool| @include_tool_names.include?(tool.name) }
      end

      def resolve_exclude_tools(resolved_tools)
        return resolved_tools if @exclude_tool_names.empty?

        resolved_tools.reject { |tool| @exclude_tool_names.include?(tool.name) }
      end

      def normalize_names(names)
        names.flatten.compact.map(&:to_s).uniq
      end
    end
  end
end
