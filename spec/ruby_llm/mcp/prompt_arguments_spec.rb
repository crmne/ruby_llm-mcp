# frozen_string_literal: true

# Can also run without the MCP fixture servers:
# bundle exec rspec --options /dev/null spec/ruby_llm/mcp/prompt_arguments_spec.rb
require "ruby_llm/mcp"

RSpec.describe RubyLLM::MCP::Prompt do
  describe "#include argument validation" do
    let(:adapter) { instance_double(RubyLLM::MCP::Adapters::RubyLLMAdapter) }
    let(:chat) { instance_double(RubyLLM::Chat, add_message: nil) }
    let(:prompt) do
      described_class.new(
        adapter,
        "name" => "greet",
        "description" => "Greets the user",
        "arguments" => [
          { "name" => "topic", "description" => "The topic", "required" => true },
          { "name" => "tone", "description" => "Optional tone", "required" => false }
        ]
      )
    end

    before do
      empty_messages = RubyLLM::MCP::Result.new({ "result" => { "messages" => [] } })
      allow(adapter).to receive(:execute_prompt).and_return(empty_messages)
    end

    it "raises PromptArgumentError when a required argument is missing" do
      expect { prompt.include(chat, arguments: { "tone" => "warm" }) }
        .to raise_error(RubyLLM::MCP::Errors::PromptArgumentError, "Argument topic is required")
    end

    it "passes when the required argument is present with a string key" do
      expect { prompt.include(chat, arguments: { "topic" => "weather", "tone" => "warm" }) }.not_to raise_error
    end

    it "passes when the required argument is present with a symbol key" do
      expect { prompt.include(chat, arguments: { topic: "weather" }) }.not_to raise_error
    end

    it "passes when only the optional argument is missing" do
      expect { prompt.include(chat, arguments: { "topic" => "weather" }) }.not_to raise_error
    end
  end
end
