---
layout: default
title: Official MCP SDK 0.25
parent: Guides
nav_order: 3
description: "Use the official MCP Ruby SDK 0.25 adapter, transports, OAuth providers, sampling, elicitation, and advanced APIs."
---

# Official MCP SDK 0.25

The `:mcp_sdk` adapter delegates protocol lifecycle and transport behavior to the official Model Context Protocol Ruby SDK. It is independent from RubyLLM::MCP's native implementation: choosing this adapter uses `MCP::Client`, `MCP::Client::Stdio`, or `MCP::Client::HTTP` end to end.

Use `:ruby_llm` when you need legacy SSE, roots, subscriptions, progress/logging callbacks, tasks, or the full native notification pipeline. Installing `mcp` does not change native clients.

## Installation

Stdio requires the official SDK:

```ruby
gem "ruby_llm-mcp"
gem "mcp", "~> 0.25"
```

Streamable HTTP also requires the SDK's optional HTTP dependencies:

```ruby
gem "faraday", ">= 2"
gem "event_stream_parser", ">= 1"
```

## Transports

### Stdio

```ruby
client = RubyLLM::MCP.client(
  name: "local-sdk-server",
  adapter: :mcp_sdk,
  transport_type: :stdio,
  request_timeout: 8_000,
  config: {
    command: "npx",
    args: ["@modelcontextprotocol/server-filesystem", Dir.pwd],
    env: { "NODE_ENV" => "production" },
    max_line_bytes: 4 * 1024 * 1024
  }
)
```

`request_timeout` remains milliseconds in RubyLLM::MCP and is converted to the SDK's seconds-based read timeout.

### Streamable HTTP

`:http`, `:streamable`, and `:streamable_http` all select `MCP::Client::HTTP`:

```ruby
client = RubyLLM::MCP.client(
  name: "remote-sdk-server",
  adapter: :mcp_sdk,
  transport_type: :streamable_http,
  request_timeout: 10_000,
  config: {
    url: "https://mcp.example.com/mcp",
    headers: { "X-Tenant" => ENV.fetch("TENANT_ID") },
    max_message_bytes: 4 * 1024 * 1024
  }
)
```

Legacy `transport_type: :sse` is native-only. Use `adapter: :ruby_llm` for an older SSE endpoint.

You can customize the SDK's Faraday connection without replacing its transport:

```ruby
config: {
  url: "https://mcp.example.com/mcp",
  faraday: lambda do |connection|
    connection.headers["User-Agent"] = "my-app/1.0"
  end
}
```

## Features by Transport

| Feature | SDK stdio | SDK HTTP | Native adapter |
|:--|:--:|:--:|:--:|
| Tools, resources, prompts, templates | Yes | Yes | Yes |
| Completions and automatic pagination | Yes | Yes | Yes |
| Structured tool output and `_meta` | Yes | Yes | Yes |
| Cache hints (`ttlMs`, `cacheScope`) | Yes | Yes | Manual refresh |
| Extension/MCP Apps negotiation | Yes | Yes | Yes |
| Official OAuth providers | No | Yes | No; uses native OAuth |
| Sampling and elicitation | No | Yes | Yes |
| Roots, subscriptions, tasks | No | No | Yes |
| Progress and logging callbacks | No | No | Yes |
| Legacy SSE | No | No | Yes |

The SDK's general transports do not expose notification hooks for RubyLLM::MCP logging or progress callbacks. Use `:ruby_llm` when those callbacks are part of your application contract.

## Lifecycle and Capabilities

Starting an SDK client performs the official initialization handshake. These methods now reflect the connected SDK session:

```ruby
client.alive?             # MCP::Client#connected?
client.ping               # real MCP ping
client.capabilities       # negotiated server capabilities
client.client_capabilities
client.restart!           # closes and performs a fresh handshake
```

An expired HTTP session raises `RubyLLM::MCP::Errors::SessionExpiredError`. Call `restart!` before retrying. RubyLLM::MCP never automatically retries a tool call because it may have already caused a side effect.

## Sampling over HTTP

Configure sampling and its model selection before starting the client:

```ruby
RubyLLM::MCP.configure do |config|
  config.sampling.enabled = true
  config.sampling.tools = true
  config.sampling.context = true
  config.sampling.preferred_model { |_preferences| "gpt-4.1-mini" }
end

client = RubyLLM::MCP::Client.new(
  name: "sampling-server",
  adapter: :mcp_sdk,
  transport_type: :streamable_http,
  start: false,
  config: { url: "https://mcp.example.com/mcp" }
)

client.on_sampling do |sample|
  # Return false to reject, or use the existing Sample handler contract.
  puts sample.message
  true
end

client.start
```

Only SDK HTTP advertises sampling. SDK stdio does not expose server-request handlers in version 0.25.

## Elicitation over HTTP

```ruby
RubyLLM::MCP.configure do |config|
  config.elicitation.form = true
  config.elicitation.url = false
end

client = RubyLLM::MCP::Client.new(
  name: "elicitation-server",
  adapter: :mcp_sdk,
  transport_type: :streamable_http,
  start: false,
  config: { url: "https://mcp.example.com/mcp" }
)

client.on_elicitation do |elicitation|
  {
    action: :accept,
    response: { "confirmed" => true }
  }
end

client.start
```

Existing synchronous handler classes, promises, and async responses are bridged to the SDK's server-request response. An async response that exceeds `request_timeout` is cancelled.

## Official OAuth Providers

SDK HTTP accepts an official provider directly:

```ruby
provider = MCP::Client::OAuth::Provider.new(
  client_metadata: {
    client_name: "My Ruby App",
    redirect_uris: ["http://127.0.0.1:9292/callback"],
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none"
  },
  redirect_uri: "http://127.0.0.1:9292/callback",
  redirect_handler: ->(url) { Launchy.open(url.to_s) },
  callback_handler: -> { wait_for_oauth_callback },
  scope: "mcp:read mcp:write"
)

client = RubyLLM::MCP.client(
  name: "oauth-sdk-server",
  adapter: :mcp_sdk,
  transport_type: :streamable_http,
  config: {
    url: "https://mcp.example.com/mcp",
    oauth: provider
  }
)
```

`oauth: { provider: provider }` is equivalent.

### Client credentials

```ruby
provider = MCP::Client::OAuth::ClientCredentialsProvider.new(
  client_id: ENV.fetch("MCP_CLIENT_ID"),
  client_secret: ENV.fetch("MCP_CLIENT_SECRET"),
  token_endpoint_auth_method: "client_secret_basic",
  scope: "mcp:read"
)
```

Use `client_secret_post` when required by the authorization server. For `private_key_jwt`:

```ruby
provider = MCP::Client::OAuth::ClientCredentialsProvider.new(
  client_id: ENV.fetch("MCP_CLIENT_ID"),
  token_endpoint_auth_method: "private_key_jwt",
  private_key: ENV.fetch("MCP_PRIVATE_KEY_PEM"),
  signing_algorithm: "RS256",
  scope: "mcp:read"
)
```

### Cross-App Access / ID-JAG

```ruby
provider = MCP::Client::OAuth::CrossAppAccessProvider.new(
  client_id: ENV.fetch("MCP_CLIENT_ID"),
  client_secret: ENV.fetch("MCP_CLIENT_SECRET"),
  assertion_provider: lambda do |audience:, resource:|
    exchange_id_token_for_id_jag(audience: audience, resource: resource)
  end,
  scope: "mcp:read"
)
```

Native `RubyLLM::MCP::Auth::OAuthProvider` objects are not interchangeable with official SDK providers. Native clients continue to use the OAuth configuration documented in the [OAuth guide]({% link guides/oauth.md %}).

## Extensions and MCP Apps

Configured extensions are passed through the official initialization handshake:

```ruby
client = RubyLLM::MCP.client(
  name: "apps-sdk-server",
  adapter: :mcp_sdk,
  transport_type: :streamable_http,
  config: {
    url: "https://mcp.example.com/mcp",
    extensions: {
      "io.modelcontextprotocol/ui" => {
        "mimeTypes" => ["text/html;profile=mcp-app"]
      }
    }
  }
)
```

Tool/resource `_meta`, titles, icons, annotations, sizes, and output schemas remain available through the normalized RubyLLM::MCP objects.

## Pagination and Cache Hints

Collection methods automatically follow `nextCursor`. RubyLLM::MCP honors SDK cache hints:

```ruby
client.tools
client.cache_hints[:tools]
# => { ttl_ms: 30000, cache_scope: "private" }
```

`ttlMs: 0` disables the collection cache. A positive TTL refreshes after expiry. Missing TTL preserves the existing manual-refresh behavior. Resource reads expose their policy through `resource.cache_hint`.

## Direct SDK Access

Use `sdk_client` for upstream APIs that do not belong in the shared abstraction:

```ruby
sdk = client.sdk_client

cancellation = MCP::Cancellation.new
result = sdk.call_tool(
  name: "long_operation",
  arguments: { "input" => "value" },
  cancellation: cancellation,
  meta: { "traceparent" => "00-..." }
)
```

Direct calls return upstream SDK objects and exceptions; they bypass RubyLLM::MCP normalization and cache management.

## Migrating from SDK 0.7

1. Change the dependency to `gem "mcp", "~> 0.25"`.
2. Add Faraday and `event_stream_parser` when using HTTP.
3. Change SDK `transport_type: :sse` clients to either:
   - `adapter: :ruby_llm` for legacy SSE, or
   - `transport_type: :streamable_http` for modern MCP HTTP.
4. Replace native-style OAuth hashes/providers on SDK clients with an official `MCP::Client::OAuth` provider.
5. Remove SDK-only `version`, `reconnection`, `session_id`, and `rate_limit` settings. The official SDK owns sessions/reconnection; customize HTTP through Faraday when needed.
6. Move logging/progress callback clients to `adapter: :ruby_llm`.
7. Expect `start` to perform a real handshake and `ping` to contact the server.

The stable integration targets MCP `2025-11-25`. The draft `2026-07-28` multi-round-trip input/resume flow is not implemented by SDK 0.25; an `input_required` result raises an unsupported-feature error instead of being treated as a final tool result.
