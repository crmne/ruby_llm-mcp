# frozen_string_literal: true

# Can also run without the MCP fixture servers:
# bundle exec rspec --options /dev/null spec/ruby_llm/mcp/ruby_llm_compatibility_spec.rb
require "ruby_llm/mcp"

RSpec.describe "RubyLLM compatibility" do # rubocop:disable RSpec/DescribeClass
  let(:adapter) { double("Adapter") }
  let(:schema) do
    { "type" => "object", "properties" => { "query" => { "type" => "string" } }, "required" => ["query"] }
  end
  let(:tool) do
    RubyLLM::MCP::Tool.new(adapter, { "name" => "search", "description" => "Search", "inputSchema" => schema })
  end
  let(:image) { { "type" => "image", "data" => Base64.strict_encode64("image bytes"), "mimeType" => "image/png" } }
  let(:audio) { { "type" => "audio", "data" => Base64.strict_encode64("audio bytes"), "mimeType" => "audio/wav" } }

  def stub_result(value)
    result = RubyLLM::MCP::Result.new({ "result" => value })
    allow(adapter).to receive(:execute_tool).with(name: "search", parameters: { query: "hello" }).and_return(result)
  end

  # RubyLLM 1 keeps an MCP::Content as the message content (normalized to a
  # plain String when it has no attachments); RubyLLM 2 stores text and
  # attachments on the message itself.
  def message_text(message)
    content = message.content
    content.respond_to?(:text) ? content.text : content
  end

  def message_attachments(message)
    content = message.content
    if content.respond_to?(:attachments)
      content.attachments
    elsif message.respond_to?(:attachments)
      message.attachments
    else
      []
    end
  end

  def sampling_request(messages, system_prompt: nil)
    params = { "messages" => messages, "systemPrompt" => system_prompt }.compact
    RubyLLM::MCP::Sample.new(RubyLLM::MCP::Result.new({ "id" => "1", "params" => params }), nil)
  end

  def split_result(result)
    if defined?(RubyLLM::Content)
      [result.text, result.attachments]
    else
      RubyLLM::Tool.split_result(result)
    end
  end

  it "exposes the complete server schema through both RubyLLM APIs" do
    expect(tool.params_schema).to eq(schema)
    expect(tool.parameters_schema).to eq(schema)
  end

  it "returns text through RubyLLM's tool invocation" do
    stub_result("content" => [{ "type" => "text", "text" => "hello" }])

    expect(split_result(tool.call(query: "hello"))).to eq(["hello", []])
  end

  it "preserves every text and attachment block in a mixed result" do
    stub_result("content" => [{ "type" => "text", "text" => "first" }, image,
                              { "type" => "text", "text" => "second" }, audio, image])

    text, attachments = split_result(tool.call(query: "hello"))

    expect(text).to eq("first\nsecond")
    expect(attachments.map(&:mime_type)).to eq(%w[image/png audio/wav image/png])
    expect(attachments.map(&:content)).to eq(["image bytes", "audio bytes", "image bytes"])
    expect(attachments.first.encoded).to eq(image["data"])
    expect(attachments.first.source).to be_a(StringIO)
  end

  it "preserves all attachments in a result without text" do
    stub_result("content" => [image, audio])

    text, attachments = split_result(tool.call(query: "hello"))

    expect(text).to eq("")
    expect(attachments.map(&:mime_type)).to eq(%w[image/png audio/wav])
  end

  it "handles empty results" do
    stub_result("content" => [])

    expect(split_result(tool.call(query: "hello"))).to eq(["", []])
  end

  it "keeps execution errors visible" do
    stub_result("isError" => true, "content" => [{ "type" => "text", "text" => "failed" }])

    expect(tool.call(query: "hello")).to eq(error: "Tool execution error: failed")
  end

  it "keeps validated structured content authoritative" do
    tool = RubyLLM::MCP::Tool.new(adapter, { "name" => "search", "inputSchema" => schema, "outputSchema" => schema })
    stub_result("structuredContent" => { "query" => "answer" }, "content" => [image])

    text, attachments = split_result(tool.call(query: "hello"))

    expect(JSON.parse(text)).to eq("query" => "answer")
    expect(attachments).to be_empty
  end

  it "preserves embedded resources alongside other tool blocks" do
    resource = { "type" => "resource", "resource" => { "uri" => "file:///result.png",
                                                       "mimeType" => "image/png", "blob" => image["data"] } }
    stub_result("content" => [resource, audio])

    text, attachments = split_result(tool.call(query: "hello"))

    expect(text).to include("search: Search")
    expect(attachments.map(&:content)).to eq(["image bytes", "audio bytes"])
  end

  it "builds messages from resource content without losing attachments" do
    resource = RubyLLM::MCP::Resource.new(adapter, "name" => "Picture", "uri" => "file:///result.png",
                                                   "mimeType" => "image/png",
                                                   "content_response" => { "blob" => image["data"] })
    chat = double("Chat")
    expect(chat).to receive(:add_message) do |message|
      content = defined?(RubyLLM::Content) ? message.content : message
      expect(defined?(RubyLLM::Content) ? content.text : content.content).to include("Picture")
      expect(content.attachments.first.content).to eq("image bytes")
    end

    resource.include(chat)
  end

  it "builds messages from MCP prompt images" do
    prompt = RubyLLM::MCP::Prompt.new(adapter, "name" => "picture")
    result = RubyLLM::MCP::Result.new({ "result" => { "messages" => [{ "role" => "user", "content" => image }] } })
    allow(adapter).to receive(:execute_prompt).with(name: "picture", arguments: {}).and_return(result)

    message = prompt.fetch.first
    content = defined?(RubyLLM::Content) ? message.content : message

    expect(content.attachments.first.content).to eq("image bytes")
  end

  it "builds sampling request messages with the installed RubyLLM message API" do
    text = { "role" => "user", "content" => { "type" => "text", "text" => "Describe this" } }
    picture = { "role" => "user", "content" => image }
    sample = sampling_request([text, picture])

    text_message = sample.send(:create_message, text)
    image_message = sample.send(:create_message, picture)

    expect(text_message).to be_a(RubyLLM::Message)
    expect(text_message.role).to eq(:user)
    expect(message_text(text_message)).to eq("Describe this")
    expect(message_attachments(text_message)).to be_empty
    expect(message_attachments(image_message).map(&:content)).to eq(["image bytes"])
  end

  it "builds sampling handler messages with the installed RubyLLM message API" do
    handler_class = Class.new do
      include RubyLLM::MCP::Handlers::Concerns::SamplingActions

      def initialize(sample)
        @sample = sample
      end
    end
    picture = { "role" => "user", "content" => image }
    handler = handler_class.new(sampling_request([picture], system_prompt: "Be brief"))

    system_message = handler.send(:system_message)
    image_message = handler.send(:create_message, picture)

    expect(system_message.role).to eq(:system)
    expect(message_text(system_message)).to eq("Be brief")
    expect(message_attachments(image_message).map(&:content)).to eq(["image bytes"])
  end

  it "asks the model to continue an assistant-ended prompt with the installed RubyLLM chat API" do
    prompt = RubyLLM::MCP::Prompt.new(adapter, "name" => "prefill")
    messages = [{ "role" => "assistant", "content" => { "type" => "text", "text" => "The answer is" } }]
    result = RubyLLM::MCP::Result.new({ "result" => { "messages" => messages } })
    allow(adapter).to receive(:execute_prompt).with(name: "prefill", arguments: {}).and_return(result)
    chat = RubyLLM.context { |config| config.openai_api_key = "test" }.chat(model: "gpt-4.1", provider: :openai)
    if RubyLLM::Chat.method_defined?(:generate)
      expect(chat).to receive(:generate).ordered
    end
    expect(chat).to receive(:complete).ordered.and_return(:generated)

    expect(prompt.ask(chat)).to eq(:generated)
  end

  it "formats text sampling responses with the installed RubyLLM message API" do
    message = RubyLLM::Message.new(role: :assistant, content: "hello")
    response = RubyLLM::MCP::Native::Messages::Responses.sampling_create_message(id: 1, message: message, model: "test")

    expect(response[:result][:content]).to eq(type: "text", text: "hello")
  end

  it "reports the installed RubyLLM message's finish reason as the MCP stop reason" do
    message = RubyLLM::Message.new(role: :assistant, content: "hello", finish_reason: :max_tokens)
    expected = RubyLLM::Message.method_defined?(:finish_reason) ? "maxTokens" : "endTurn"
    response = RubyLLM::MCP::Native::Messages::Responses.sampling_create_message(id: 1, message: message, model: "test")

    expect(response[:result][:stopReason]).to eq(expected)
  end

  it "formats image sampling responses with base64 data" do
    attachment = RubyLLM::MCP::Attachment.new(image["data"], image["mimeType"])
    content = RubyLLM::MCP::Content.new(attachments: [attachment])
    message = RubyLLM::Message.new(role: :assistant, **content.message_options)
    response = RubyLLM::MCP::Native::Messages::Responses.sampling_create_message(id: 1, message: message, model: "test")

    expect(response[:result][:content]).to eq(type: :image, data: image["data"], mimeType: "image/png")
  end
end
