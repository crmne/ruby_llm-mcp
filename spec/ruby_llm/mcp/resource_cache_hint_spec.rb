# frozen_string_literal: true

RSpec.describe RubyLLM::MCP::Resource do
  let(:adapter) { instance_double(RubyLLM::MCP::Adapters::BaseAdapter) }
  let(:resource) do
    described_class.new(
      adapter,
      {
        "name" => "hinted",
        "uri" => "test://hinted",
        "mimeType" => "text/plain"
      }
    )
  end

  it "expires resource content using read ttlMs while exposing cache scope" do
    allow(adapter).to receive(:resource_read).and_return(
      RubyLLM::MCP::Result.new({
                                 "result" => {
                                   "contents" => [{ "uri" => "test://hinted", "text" => "first" }],
                                   "ttlMs" => 5,
                                   "cacheScope" => "private"
                                 }
                               }),
      RubyLLM::MCP::Result.new({
                                 "result" => {
                                   "contents" => [{ "uri" => "test://hinted", "text" => "second" }],
                                   "ttlMs" => 5,
                                   "cacheScope" => "private"
                                 }
                               })
    )

    expect(resource.content).to eq("first")
    expect(resource.content).to eq("first")
    expect(adapter).to have_received(:resource_read).once
    expect(resource.cache_hint).to eq(ttl_ms: 5, cache_scope: "private")

    sleep 0.01
    expect(resource.content).to eq("second")
    expect(adapter).to have_received(:resource_read).twice
  end

  it "does not cache content when ttlMs is zero" do
    allow(adapter).to receive(:resource_read).and_return(
      RubyLLM::MCP::Result.new({
                                 "result" => { "contents" => [{ "uri" => "test://hinted", "text" => "value" }],
                                               "ttlMs" => 0 }
                               })
    )

    2.times { expect(resource.content).to eq("value") }
    expect(adapter).to have_received(:resource_read).twice
  end
end
