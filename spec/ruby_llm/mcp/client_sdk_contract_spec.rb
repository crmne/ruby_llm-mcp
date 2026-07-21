# frozen_string_literal: true

RSpec.describe RubyLLM::MCP::Client do
  let(:sdk_client) { instance_double(MCP::Client) }
  let(:capabilities) { RubyLLM::MCP::ServerCapabilities.new("tools" => {}) }
  let(:adapter) do
    instance_double(
      RubyLLM::MCP::Adapters::MCPSdkAdapter,
      start: nil,
      stop: nil,
      alive?: true,
      mcp_client: sdk_client,
      capabilities: capabilities,
      cache_hints: {}
    )
  end

  before do
    allow(adapter).to receive(:supports?) { |feature| feature == :tools }
    allow(RubyLLM::MCP::Adapters::MCPSdkAdapter).to receive(:new).and_return(adapter)
  end

  it "exposes the connected official client without leaking it into native mode" do
    client = described_class.new(
      name: "sdk-access",
      adapter: :mcp_sdk,
      transport_type: :stdio,
      start: false,
      config: { command: "unused" }
    )

    expect(client.sdk_client).to equal(sdk_client)

    native_client = described_class.new(
      name: "native-access",
      adapter: :ruby_llm,
      transport_type: :stdio,
      start: false,
      config: { command: "unused" }
    )
    expect { native_client.sdk_client }.to raise_error(
      RubyLLM::MCP::Errors::UnsupportedFeature,
      /only available.*mcp_sdk/
    )
  ensure
    native_client&.stop
  end

  it "expires collection caches according to SDK ttlMs hints" do
    allow(adapter).to receive_messages(tool_list: [
                                         { "name" => "cached",
                                           "inputSchema" => { "type" => "object", "properties" => {} } }
                                       ], cache_hints: { tools: { ttl_ms: 5, cache_scope: "private" } })
    client = described_class.new(
      name: "sdk-cache",
      adapter: :mcp_sdk,
      transport_type: :stdio,
      start: false,
      config: { command: "unused" }
    )

    expect(client.tools.map(&:name)).to eq(["cached"])
    expect(client.tools.map(&:name)).to eq(["cached"])
    expect(adapter).to have_received(:tool_list).once

    sleep 0.01
    expect(client.tools.map(&:name)).to eq(["cached"])
    expect(adapter).to have_received(:tool_list).twice
    expect(client.cache_hints).to eq(tools: { ttl_ms: 5, cache_scope: "private" })
  end

  it "does not cache a collection when ttlMs is zero" do
    allow(adapter).to receive_messages(tool_list: [
                                         { "name" => "uncached",
                                           "inputSchema" => { "type" => "object", "properties" => {} } }
                                       ], cache_hints: { tools: { ttl_ms: 0 } })
    client = described_class.new(
      name: "sdk-no-cache",
      adapter: :mcp_sdk,
      transport_type: :stdio,
      start: false,
      config: { command: "unused" }
    )

    2.times { client.tools }
    expect(adapter).to have_received(:tool_list).twice
  end
end
