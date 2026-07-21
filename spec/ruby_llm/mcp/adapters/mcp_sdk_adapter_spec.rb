# frozen_string_literal: true

RSpec.describe RubyLLM::MCP::Adapters::MCPSdkAdapter do
  # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration, RSpec/InstanceVariable
  class FakeSdkTransport
    attr_reader :connect_options, :server_info, :requests, :handlers

    def initialize(server_info: nil, &response)
      @server_info = server_info || {
        "protocolVersion" => "2025-11-25",
        "capabilities" => { "tools" => {}, "resources" => {}, "prompts" => {}, "completions" => {} }
      }
      @response = response
      @requests = []
      @handlers = {}
      @connected = false
    end

    def connect(**options)
      @connect_options = options
      @connected = true
      @server_info
    end

    def connected?
      @connected
    end

    def close
      @connected = false
      @server_info = nil
    end

    def send_request(request:)
      @requests << request
      @response ? @response.call(request) : { "jsonrpc" => "2.0", "id" => request[:id], "result" => {} }
    end

    def on_server_request(method, &handler)
      @handlers[method] = handler
    end
  end
  # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration, RSpec/InstanceVariable

  let(:client) do
    instance_double(
      RubyLLM::MCP::Client,
      name: "contract-client",
      linked_resources: [],
      on: {},
      sampling_callback_enabled?: false
    )
  end

  def build_adapter(transport_type: :stdio, config: {})
    described_class.new(
      client,
      transport_type: transport_type,
      config: { protocol_version: "2025-11-25", request_timeout: 2500 }.merge(config)
    )
  end

  def official_oauth_providers
    redirect_uri = "http://127.0.0.1:9292/callback"
    private_key = OpenSSL::PKey::RSA.generate(2048)
    [
      MCP::Client::OAuth::Provider.new(
        client_metadata: { redirect_uris: [redirect_uri] }, redirect_uri: redirect_uri,
        redirect_handler: ->(_url) {}, callback_handler: -> {}
      ),
      MCP::Client::OAuth::ClientCredentialsProvider.new(
        client_id: "client", client_secret: "secret", token_endpoint_auth_method: "client_secret_basic"
      ),
      MCP::Client::OAuth::ClientCredentialsProvider.new(
        client_id: "client", client_secret: "secret", token_endpoint_auth_method: "client_secret_post"
      ),
      MCP::Client::OAuth::ClientCredentialsProvider.new(
        client_id: "client", private_key: private_key, signing_algorithm: "RS256",
        token_endpoint_auth_method: "private_key_jwt"
      ),
      MCP::Client::OAuth::CrossAppAccessProvider.new(
        client_id: "client", client_secret: "secret",
        assertion_provider: ->(audience:, resource:) { "id-jag:#{audience}:#{resource}" }
      )
    ]
  end

  describe "adapter boundaries" do
    it "keeps native-only transports out of the SDK adapter" do
      expect do
        described_class.new(client, transport_type: :sse, config: {})
      end.to raise_error(RubyLLM::MCP::Errors::UnsupportedTransport, /Supported transports: stdio, http, streamable/)
    end

    it "reports features by transport without changing native feature declarations" do
      expect(described_class.support?(:sampling, transport: :stdio)).to be(false)
      expect(described_class.support?(:sampling, transport: :streamable_http)).to be(true)
      expect(described_class.support?(:oauth, transport: :http)).to be(true)
      expect(described_class.support?(:logging, transport: :http)).to be(false)
      expect(RubyLLM::MCP::Adapters::RubyLLMAdapter.support?(:logging, transport: :stdio)).to be(true)
    end
  end

  describe "official lifecycle" do
    let(:transport) { FakeSdkTransport.new }
    let(:adapter) { build_adapter }

    before do
      allow(MCP::Client::Stdio).to receive(:new).and_return(transport)
    end

    it "connects with client identity, protocol version, and capabilities" do
      adapter.start

      expect(transport.connect_options).to include(
        client_info: { name: "contract-client", version: RubyLLM::MCP::VERSION },
        protocol_version: "2025-11-25",
        capabilities: {}
      )
      expect(adapter).to be_alive
      expect(adapter.capabilities.tools_list?).to be(true)
      expect(adapter.ping).to be(true)
    end

    it "closes and reconnects cleanly" do
      allow(MCP::Client::Stdio).to receive(:new).and_return(transport, FakeSdkTransport.new)
      adapter.start
      first_client = adapter.mcp_client
      adapter.restart!

      expect(adapter).to be_alive
      expect(adapter.mcp_client).not_to equal(first_client)
      adapter.stop
      expect(adapter).not_to be_alive
      expect(adapter.cache_hints).to eq({})
    end

    it "forwards stdio timeout and frame limit to the SDK" do
      allow(MCP::Client::Stdio).to receive(:new).and_return(transport)
      adapter = build_adapter(config: { command: "server", args: ["--stdio"], env: { "A" => "B" },
                                        max_line_bytes: 1234 })
      adapter.start

      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "server",
        args: ["--stdio"],
        env: { "A" => "B" },
        read_timeout: 2.5,
        max_line_bytes: 1234
      )
    end
  end

  describe "official HTTP configuration" do
    let(:transport) { FakeSdkTransport.new }

    it "passes headers, an official OAuth provider, and the message limit" do
      provider = instance_double(MCP::Client::OAuth::ClientCredentialsProvider)
      allow(MCP::Client::HTTP).to receive(:new).and_return(transport)
      adapter = build_adapter(
        transport_type: :streamable_http,
        config: {
          url: "http://127.0.0.1:9292/mcp",
          headers: { "X-Test" => "yes" },
          oauth: { provider: provider },
          max_message_bytes: 4096
        }
      )
      adapter.start

      expect(MCP::Client::HTTP).to have_received(:new).with(
        url: "http://127.0.0.1:9292/mcp",
        headers: { "X-Test" => "yes" },
        oauth: provider,
        max_message_bytes: 4096
      )
    end

    it "accepts every documented official OAuth provider configuration" do
      official_oauth_providers.each_with_index do |provider, index|
        allow(MCP::Client::HTTP).to receive(:new).and_return(FakeSdkTransport.new)
        oauth = index.even? ? provider : { provider: provider }
        build_adapter(transport_type: :http, config: { url: "http://127.0.0.1:9292/mcp", oauth: oauth }).start

        expect(MCP::Client::HTTP).to have_received(:new).with(
          url: "http://127.0.0.1:9292/mcp", headers: {}, oauth: provider
        )
      end
    end

    it "rejects a native OAuth provider with migration guidance" do
      provider = RubyLLM::MCP::Auth::OAuthProvider.allocate
      adapter = build_adapter(
        transport_type: :http,
        config: { url: "http://127.0.0.1:9292/mcp", oauth: provider }
      )

      expect { adapter.start }.to raise_error(
        RubyLLM::MCP::Errors::AdapterConfigurationError,
        /MCP::Client::OAuth provider/
      )
    end
  end

  describe "payload fidelity and pagination" do
    let(:pages) do
      {
        nil => {
          "tools" => [{
            "name" => "first", "title" => "First", "description" => "one",
            "inputSchema" => { "type" => "object" }, "icons" => [{ "src" => "one.svg" }],
            "annotations" => { "readOnlyHint" => true }, "_meta" => { "ui" => { "resourceUri" => "ui://first" } }
          }],
          "nextCursor" => "page-2", "ttlMs" => 5000, "cacheScope" => "public"
        },
        "page-2" => {
          "tools" => [{ "name" => "second", "inputSchema" => { "type" => "object" } }],
          "ttlMs" => 1000, "cacheScope" => "private"
        }
      }
    end
    let(:transport) do
      FakeSdkTransport.new do |request|
        if request[:method] == "tools/list"
          cursor = request.dig(:params, :cursor)
          { "jsonrpc" => "2.0", "id" => request[:id], "result" => pages.fetch(cursor) }
        elsif request[:method] == "tools/call"
          {
            "jsonrpc" => "2.0", "id" => request[:id],
            "result" => {
              "content" => [{ "type" => "text", "text" => "ok" }],
              "structuredContent" => { "answer" => 42 }, "isError" => false,
              "_meta" => { "trace" => "kept" }
            }
          }
        else
          { "jsonrpc" => "2.0", "id" => request[:id], "result" => {} }
        end
      end
    end
    let(:adapter) { build_adapter }

    before do
      allow(MCP::Client::Stdio).to receive(:new).and_return(transport)
      adapter.start
    end

    it "walks every page and preserves fields omitted by MCP::Client::Tool" do
      tools = adapter.tool_list

      expect(tools.map { |tool| tool["name"] }).to eq(%w[first second])
      expect(tools.first).to include(
        "title" => "First",
        "icons" => [{ "src" => "one.svg" }],
        "annotations" => { "readOnlyHint" => true },
        "_meta" => { "ui" => { "resourceUri" => "ui://first" } }
      )
      expect(adapter.cache_hints[:tools]).to eq(ttl_ms: 1000, cache_scope: "private")
    end

    it "preserves structured content, execution status, and metadata" do
      result = adapter.execute_tool(name: "structured", parameters: {})

      expect(result.value).to include(
        "structuredContent" => { "answer" => 42 },
        "isError" => false,
        "_meta" => { "trace" => "kept" }
      )
    end
  end

  describe "error translation" do
    it "preserves JSON-RPC error details" do
      transport = FakeSdkTransport.new do |request|
        { "jsonrpc" => "2.0", "id" => request[:id], "error" => { "code" => -32_602, "message" => "missing" } }
      end
      allow(MCP::Client::Stdio).to receive(:new).and_return(transport)
      adapter = build_adapter
      adapter.start

      expect { adapter.tool_list }.to raise_error(RubyLLM::MCP::Errors::ResponseError) do |error|
        expect(error.error).to include("code" => -32_602, "message" => "missing")
      end
    end

    it "does not retry side-effecting calls after session expiry" do
      transport = FakeSdkTransport.new
      allow(MCP::Client::Stdio).to receive(:new).and_return(transport)
      sdk_client = instance_double(MCP::Client, transport: transport, connected?: true,
                                                server_info: transport.server_info)
      allow(sdk_client).to receive(:connect).and_return(transport.server_info)
      allow(sdk_client).to receive(:call_tool).and_raise(
        MCP::Client::SessionExpiredError.new("expired", { method: "tools/call" })
      )
      allow(MCP::Client).to receive(:new).and_return(sdk_client)
      adapter = build_adapter
      adapter.start

      expect do
        adapter.execute_tool(name: "write", parameters: {})
      end.to raise_error(RubyLLM::MCP::Errors::SessionExpiredError, /restart!/)
      expect(sdk_client).to have_received(:call_tool).once
    end
  end
end
