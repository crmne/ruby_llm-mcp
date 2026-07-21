# frozen_string_literal: true

RSpec.describe "MCP SDK server requests" do # rubocop:disable RSpec/DescribeClass
  around do |example|
    # MCP::Client::HTTP keeps a concurrent Net::HTTP SSE listener open for
    # server-to-client requests. WebMock's Net::HTTP adapter prevents that
    # listener from receiving fixture events, so these real loopback checks run
    # against the transport without interception.
    WebMock.disable!
    MCPTestConfiguration.reset_config!
    example.run
  ensure
    WebMock.enable!
    MCPTestConfiguration.reset_config!
  end

  def build_http_client(request_timeout: 5000)
    RubyLLM::MCP::Client.new(
      name: "mcp-sdk-server-requests",
      adapter: :mcp_sdk,
      transport_type: :streamable_http,
      start: false,
      request_timeout: request_timeout,
      config: { url: TestServerManager::HTTP_SERVER_URL }
    )
  end

  it "round-trips sampling through the existing RubyLLM handler contract" do
    RubyLLM::MCP.configure do |config|
      config.sampling.enabled = true
      config.sampling.preferred_model { "fixture-model" }
    end
    client = build_http_client
    client.on_sampling do |sample|
      expect(sample.message).to eq("Hello, how are you?")
      {
        accepted: true,
        response: RubyLLM::Message.new(role: "assistant", content: "SDK sampling response")
      }
    end
    client.start

    result = client.tool("sampling-test").execute

    expect(result.to_s).to include("Sampling test completed")
    expect(result.to_s).to include("SDK sampling response")
  ensure
    client&.stop
  end

  it "round-trips form elicitation through the existing RubyLLM handler contract" do
    RubyLLM::MCP.configure do |config|
      config.elicitation.form = true
      config.elicitation.url = false
    end
    client = build_http_client
    client.on_elicitation do |elicitation|
      expect(elicitation.message).to eq("Choose a value")
      { action: :accept, response: { "response" => "from-sdk", "confirmed" => true } }
    end
    client.start

    result = client.tool("simple_elicitation").execute(message: "Choose a value")

    expect(result.to_s).to include("Simple elicitation completed")
    expect(result.to_s).to include("from-sdk")
  ensure
    client&.stop
  end

  it "rejects sampling requests with the MCP user-rejection error" do
    RubyLLM::MCP.configure do |config|
      config.sampling.enabled = true
      config.sampling.preferred_model { "fixture-model" }
    end
    client = build_http_client
    client.on_sampling { false }
    client.start

    result = client.tool("sampling-test").execute

    expect(result.to_s).to include("MCP error -1")
    expect(result.to_s).to include("Sampling request was rejected")
  ensure
    client&.stop
  end

  it "preserves sampling handler errors as SDK server-request errors" do
    RubyLLM::MCP.configure do |config|
      config.sampling.enabled = true
      config.sampling.preferred_model { "fixture-model" }
    end
    client = build_http_client
    client.on_sampling { raise "sampling guard failed" }
    client.start

    result = client.tool("sampling-test").execute

    expect(result.to_s).to include("MCP error -1")
    expect(result.to_s).to include("Error executing sampling request")
  ensure
    client&.stop
  end

  it "returns decline and cancellation actions through official HTTP" do
    client = build_http_client
    actions = [{ action: :reject }, { action: :cancel }]
    client.on_elicitation { actions.shift }
    client.start

    declined = client.tool("simple_elicitation").execute(message: "decline this")
    cancelled = client.tool("simple_elicitation").execute(message: "cancel this")

    expect(declined.to_s).to include('"action":"decline"')
    expect(cancelled.to_s).to include('"action":"cancel"')
  ensure
    client&.stop
  end

  it "preserves elicitation handler failures as SDK server-request errors" do
    client = build_http_client
    client.on_elicitation { raise "approval UI unavailable" }
    client.start

    result = client.tool("simple_elicitation").execute(message: "handle failure")

    expect(result.to_s).to include("MCP error -32603")
    expect(result.to_s).to include("approval UI unavailable")
  ensure
    client&.stop
  end

  it "waits for asynchronous elicitation completion" do
    client = build_http_client
    client.on_elicitation do |elicitation|
      response = RubyLLM::MCP::Handlers::AsyncResponse.new(elicitation_id: elicitation.id)
      Thread.new do
        sleep 0.02
        response.complete({ "response" => "async-sdk", "confirmed" => true })
      end
      response
    end
    client.start

    result = client.tool("simple_elicitation").execute(message: "complete later")

    expect(result.to_s).to include("async-sdk")
  ensure
    client&.stop
  end

  it "returns cancellation when asynchronous elicitation exceeds the request timeout" do
    client = build_http_client(request_timeout: 200)
    client.on_elicitation { :pending }
    client.start

    result = client.tool("simple_elicitation").execute(message: "time out")

    expect(result.to_s).to include('"action":"cancel"')
    expect(RubyLLM::MCP::Handlers::ElicitationRegistry.size).to eq(0)
  ensure
    client&.stop
  end
end
