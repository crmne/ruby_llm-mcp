# frozen_string_literal: true

# Can also run without the MCP fixture servers:
# bundle exec rspec --options /dev/null spec/ruby_llm/mcp/generate_response_spec.rb
require "ruby_llm/mcp"

RSpec.describe RubyLLM::MCP, ".generate_response" do
  # Plain doubles so the same examples run whether or not the installed
  # RubyLLM::Chat defines #generate.
  context "when the chat defines #generate (RubyLLM 2)" do
    let(:chat) do
      double("Chat").tap do |chat|
        allow(chat).to receive(:respond_to?).with(:generate).and_return(true)
      end
    end

    it "requests a generation before completing and returns the completion" do
      final = double("Message")
      expect(chat).to receive(:generate).ordered
      expect(chat).to receive(:complete).ordered.and_return(final)

      expect(described_class.generate_response(chat)).to eq(final)
    end

    it "passes the streaming block to both calls" do
      received = []
      allow(chat).to receive(:generate) { |&block| received << block }
      allow(chat).to receive(:complete) { |&block| received << block }
      handler = proc { |chunk| chunk }

      described_class.generate_response(chat, &handler)

      expect(received).to eq([handler, handler])
    end
  end

  context "when the chat has no #generate (RubyLLM 1)" do
    let(:chat) do
      double("Chat").tap do |chat|
        allow(chat).to receive(:respond_to?).with(:generate).and_return(false)
      end
    end

    it "only completes" do
      final = double("Message")
      expect(chat).not_to receive(:generate)
      allow(chat).to receive(:complete).and_return(final)

      expect(described_class.generate_response(chat)).to eq(final)
      expect(chat).to have_received(:complete).once
    end
  end

  context "with the installed RubyLLM::Chat" do
    let(:chat) do
      RubyLLM.context { |config| config.openai_api_key = "test" }.chat(model: "gpt-4.1", provider: :openai)
    end

    it "uses #generate only when the installed chat defines it" do
      chat.add_message(role: :assistant, content: "The answer is")
      if RubyLLM::Chat.method_defined?(:generate)
        expect(chat).to receive(:generate).ordered
      end
      expect(chat).to receive(:complete).ordered.and_return(:generated)

      expect(described_class.generate_response(chat)).to eq(:generated)
    end
  end

  it "makes Sample#chat request a generation for assistant-ended sampling requests" do
    input = RubyLLM::MCP::Result.new(
      {
        "id" => "123",
        "params" => {
          "messages" => [
            { "role" => "user", "content" => { "type" => "text", "text" => "Continue this answer" } },
            { "role" => "assistant", "content" => { "type" => "text", "text" => "The answer is" } }
          ]
        }
      }
    )
    sample = RubyLLM::MCP::Sample.new(input, nil)
    chat = double("Chat")
    allow(RubyLLM::Chat).to receive(:new).and_return(chat)
    allow(chat).to receive(:add_message)
    allow(chat).to receive(:respond_to?).with(:generate).and_return(true)
    expect(chat).to receive(:generate).ordered
    expect(chat).to receive(:complete).ordered.and_return(:generated)

    expect(sample.send(:chat, "gpt-4.1")).to eq(:generated)
  end
end
