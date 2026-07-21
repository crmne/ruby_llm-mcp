# frozen_string_literal: true

RSpec.describe "Native adapter isolation" do # rubocop:disable RSpec/DescribeClass
  it "uses RubyLLM::MCP native protocol and transport objects when mcp 0.25 is installed" do
    expect(defined?(MCP::VERSION)).to eq("constant")
    sdk_version = Gem::Version.new(MCP::VERSION)
    expect(sdk_version).to be >= Gem::Version.new("0.25.0")
    expect(sdk_version).to be < Gem::Version.new("1.0.0")

    client = RubyLLM::MCP::Client.new(
      name: "native-isolation",
      adapter: :ruby_llm,
      transport_type: :stdio,
      start: false,
      config: { command: "unused" }
    )

    expect(client.adapter).to be_a(RubyLLM::MCP::Adapters::RubyLLMAdapter)
    expect(client.adapter.native_client).to be_a(RubyLLM::MCP::Native::Client)
    expect(client.adapter.native_client.transport).to be_a(RubyLLM::MCP::Native::Transport)
    expect(client.adapter).not_to respond_to(:mcp_client)
  ensure
    client&.stop
  end
end
