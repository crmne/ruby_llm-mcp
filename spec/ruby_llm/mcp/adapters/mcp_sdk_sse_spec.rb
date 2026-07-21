# frozen_string_literal: true

RSpec.describe RubyLLM::MCP::Adapters::MCPSdkAdapter do # rubocop:disable RSpec/SpecFilePathFormat
  it "keeps legacy SSE on the native adapter" do
    expect do
      RubyLLM::MCP::Client.new(
        name: "legacy-sse",
        adapter: :mcp_sdk,
        transport_type: :sse,
        start: false,
        config: { url: "http://localhost:3006/mcp/sse" }
      )
    end.to raise_error(
      RubyLLM::MCP::Errors::AdapterConfigurationError,
      /Use adapter: :ruby_llm for legacy SSE/
    )
  end
end
