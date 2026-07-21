# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyLLM::MCP::Toolset do
  let(:read_file) { instance_double(RubyLLM::MCP::Tool, name: "read_file") }
  let(:delete_file) { instance_double(RubyLLM::MCP::Tool, name: "delete_file") }
  let(:list_projects) { instance_double(RubyLLM::MCP::Tool, name: "list_projects") }
  let(:duplicate_read_file) { instance_double(RubyLLM::MCP::Tool, name: "read_file") }
  let(:filesystem_client) do
    instance_double(RubyLLM::MCP::Client, name: "filesystem", tools: [read_file, delete_file])
  end
  let(:projects_client) do
    instance_double(RubyLLM::MCP::Client, name: "projects", tools: [list_projects, duplicate_read_file])
  end
  let(:clients_map) do
    {
      "filesystem" => filesystem_client,
      "projects" => projects_client
    }
  end

  describe "#tools" do
    it "filters to configured client names" do
      toolset = described_class.new(name: :support).from_clients("filesystem")

      tool_names = toolset.tools(clients: clients_map).map(&:name)
      expect(tool_names).to contain_exactly("read_file", "delete_file")
    end

    it "raises when a configured client name is missing" do
      toolset = described_class.new(name: :support).from_clients("missing_client")

      expect do
        toolset.tools(clients: clients_map)
      end.to raise_error(
        RubyLLM::MCP::Errors::ConfigurationError,
        /Unknown MCP client name\(s\): missing_client/
      )
    end

    it "raises when configured clients are missing from an empty client collection" do
      toolset = described_class.new(name: :support).from_clients("missing_client")

      expect do
        toolset.tools(clients: [])
      end.to raise_error(
        RubyLLM::MCP::Errors::ConfigurationError,
        /Unknown MCP client name\(s\): missing_client/
      )
    end

    it "supports include and exclude filters together" do
      toolset = described_class.new(name: :support)
                               .include_tools("read_file", "list_projects")
                               .exclude_tools("list_projects")

      tool_names = toolset.tools(clients: clients_map).map(&:name)
      expect(tool_names).to eq(["read_file"])
    end

    it "deduplicates tools by name across clients" do
      toolset = described_class.new(name: :support)

      tool_names = toolset.tools(clients: clients_map).map(&:name)
      expect(tool_names).to contain_exactly("read_file", "delete_file", "list_projects")
    end
  end

  describe "#with_tools" do
    it "keeps selected clients connected for the duration of the block" do
      toolset = described_class.new(name: :support).from_clients("filesystem")
      allow(RubyLLM::MCP).to receive(:establish_connection)
        .with(client_names: ["filesystem"])
        .and_yield(clients_map)

      result = toolset.with_tools do |tools|
        expect(tools.map(&:name)).to contain_exactly("read_file", "delete_file")
        :completed
      end

      expect(result).to eq(:completed)
    end

    it "does not expose an array conversion that returns disconnected tools" do
      toolset = described_class.new(name: :support)

      expect(toolset).not_to respond_to(:to_a)
    end
  end
end
