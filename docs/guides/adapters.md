---
layout: default
title: Adapters & Transports
parent: Guides
nav_order: 4
description: "Choose between RubyLLM::MCP's native implementation and the official MCP SDK 0.25."
---

# Adapters & Transports

RubyLLM::MCP has two independent client implementations. They share the public RubyLLM::MCP objects, but they do not share protocol or transport internals.

## Adapter Boundaries

### Native (`:ruby_llm`)

The default adapter uses this gem's established `RubyLLM::MCP::Native` client and transports. Installing the optional `mcp` gem does not replace or modify this path.

Choose native for:

- Stdio, legacy SSE, and Streamable HTTP using RubyLLM::MCP transports
- Roots and resource subscriptions
- Logging, progress, and list-changed notifications
- Sampling, elicitation, and human-in-the-loop approval
- Task lifecycle APIs
- Custom native transport registration

```ruby
client = RubyLLM::MCP.client(
  name: "native-server",
  adapter: :ruby_llm,
  transport_type: :streamable,
  config: { url: "https://example.com/mcp" }
)
```

### Official SDK (`:mcp_sdk`)

This adapter requires `mcp ~> 0.25` and delegates lifecycle and communication to the official Model Context Protocol Ruby SDK.

Choose it for:

- Official `MCP::Client::Stdio` and `MCP::Client::HTTP` transports
- Official initialization, session, reconnection, cancellation, and ping behavior
- Tools, resources, prompts, templates, completions, and pagination
- Structured output, metadata, cache hints, and extension negotiation
- Official HTTP OAuth providers, sampling, and elicitation
- Direct access to the connected `MCP::Client`

```ruby
client = RubyLLM::MCP.client(
  name: "official-sdk-server",
  adapter: :mcp_sdk,
  transport_type: :streamable_http,
  config: { url: "https://example.com/mcp" }
)
```

See [Official MCP SDK 0.25]({% link guides/mcp-sdk-0.25.md %}) for complete installation, OAuth, server-request, and migration examples.

## Feature Matrix

| Feature | Native stdio | Native HTTP/SSE | SDK stdio | SDK HTTP |
|:--|:--:|:--:|:--:|:--:|
| Tools, resources, prompts, templates | Yes | Yes | Yes | Yes |
| Completions and pagination | Yes | Yes | Yes | Yes |
| Structured tool output | Yes | Yes | Yes | Yes |
| Extension/MCP Apps negotiation | Yes | Yes | Yes | Yes |
| SDK cache-hint expiry | — | — | Yes | Yes |
| Sampling and elicitation | Yes | Yes | No | Yes |
| OAuth | — | Native provider | No | Official SDK provider |
| Roots and subscriptions | Yes | Yes | No | No |
| Logging/progress callbacks | Yes | Yes | No | No |
| Tasks | Yes | Yes | No | No |
| Legacy SSE | No | Yes | No | No |

Feature checks are transport-aware. For example, `client.on_sampling` is valid for SDK HTTP but raises `UnsupportedFeature` for SDK stdio.

## Transport Matrix

| Configuration | Implementation |
|:--|:--|
| `adapter: :ruby_llm, transport_type: :stdio` | RubyLLM::MCP native stdio |
| `adapter: :ruby_llm, transport_type: :sse` | RubyLLM::MCP legacy SSE |
| `adapter: :ruby_llm, transport_type: :streamable` | RubyLLM::MCP Streamable HTTP |
| `adapter: :mcp_sdk, transport_type: :stdio` | `MCP::Client::Stdio` |
| `adapter: :mcp_sdk, transport_type: :http` | `MCP::Client::HTTP` |
| `adapter: :mcp_sdk, transport_type: :streamable` | `MCP::Client::HTTP` |
| `adapter: :mcp_sdk, transport_type: :streamable_http` | `MCP::Client::HTTP` |

SDK legacy SSE is intentionally rejected with migration guidance. Either use the native adapter for that endpoint or migrate the server to Streamable HTTP.

## Installation

The native adapter has no dependency on the official SDK. For `:mcp_sdk` stdio:

```ruby
gem "mcp", "~> 0.25"
```

For SDK HTTP also add:

```ruby
gem "faraday", ">= 2"
gem "event_stream_parser", ">= 1"
```

## Common Configuration

Select a default adapter:

```ruby
RubyLLM::MCP.configure do |config|
  config.default_adapter = :ruby_llm
end
```

Override it per client:

```ruby
native = RubyLLM::MCP.client(
  name: "native",
  adapter: :ruby_llm,
  transport_type: :stdio,
  config: { command: "native-server" }
)

official = RubyLLM::MCP.client(
  name: "official",
  adapter: :mcp_sdk,
  transport_type: :stdio,
  config: { command: "official-server" }
)
```

Both clients expose the same normalized tools, resources, templates, and prompts.

## SDK-Specific Options

```ruby
client = RubyLLM::MCP.client(
  name: "official",
  adapter: :mcp_sdk,
  transport_type: :streamable_http,
  request_timeout: 8_000,
  config: {
    url: "https://example.com/mcp",
    headers: { "Authorization" => "Bearer static-token" },
    max_message_bytes: 4 * 1024 * 1024,
    oauth: official_oauth_provider,
    faraday: ->(connection) { connection.headers["User-Agent"] = "my-app/1.0" }
  }
)
```

For stdio, use `max_line_bytes`. The shared `request_timeout` remains milliseconds and is converted before being passed to the SDK.

The old custom SDK-wrapper options `version`, `reconnection`, `session_id`, and `rate_limit` do not configure the official transports. The SDK manages sessions and reconnection; use Faraday customization for HTTP middleware behavior.

## Advanced SDK Access

```ruby
sdk = client.sdk_client
page = sdk.list_tools
```

`sdk_client` is available only with `adapter: :mcp_sdk`. Raw SDK calls bypass RubyLLM::MCP normalization and use upstream result/error types.

## Custom Native Transports

Custom transports remain a native concern:

```ruby
RubyLLM::MCP::Native::Transport.register_transport(:websocket, WebSocketTransport)
```

Registering a native transport never makes it available to `:mcp_sdk`. The official adapter deliberately accepts only transports implemented by the upstream SDK.

## Unsupported Features

Calling a feature outside the chosen adapter/transport contract raises a focused error:

```ruby
client = RubyLLM::MCP.client(
  name: "sdk-stdio",
  adapter: :mcp_sdk,
  transport_type: :stdio,
  config: { command: "server" }
)

client.on_progress { |progress| puts progress }
# RubyLLM::MCP::Errors::UnsupportedFeature
```

Switch to `:ruby_llm` when the missing feature is notification-, root-, subscription-, task-, or legacy-transport-oriented.
