# frozen_string_literal: true

module RubyLLM
  module MCP
    class Resource
      attr_reader :uri, :name, :title, :description, :mime_type, :adapter, :subscribed, :apps_metadata,
                  :annotations, :icons, :size, :meta, :cache_hint

      def initialize(adapter, resource)
        @adapter = adapter
        @uri = resource["uri"]
        @name = resource["name"]
        @title = resource["title"]
        @description = resource["description"]
        @mime_type = resource["mimeType"]
        @annotations = resource["annotations"]
        @icons = resource["icons"] || []
        @size = resource["size"]
        @meta = resource["_meta"] || {}
        @cache_hint = nil
        @content_expires_at = nil
        @apps_metadata = Extensions::Apps::ResourceMetadata.new(resource[Extensions::Apps::Constants::META_KEY])
        if resource.key?("content_response")
          @content_response = resource["content_response"]
          @content = @content_response["text"] || @content_response["blob"]
        end

        @subscribed = false
      end

      def content
        reset_content! if content_cache_expired?
        return @content unless @content.nil?

        result = read_response
        result.raise_error! if result.error?

        @content_response = result.value.dig("contents", 0)
        @content = @content_response["text"] || @content_response["blob"]
        apply_cache_hint(result.value)
        @content
      end

      def content_loaded?
        !@content.nil?
      end

      def subscribe!
        if @adapter.capabilities.resource_subscribe?
          @adapter.resources_subscribe(uri: @uri)
          @subscribed = true
        else
          message = "Resource subscribe is not available for this MCP server"
          raise Errors::Capabilities::ResourceSubscribeNotAvailable.new(message: message)
        end
      end

      def unsubscribe!
        if @adapter.capabilities.resource_subscribe?
          @adapter.resources_unsubscribe(uri: @uri)
          @subscribed = false
        else
          message = "Resource unsubscribe is not available for this MCP server"
          raise Errors::Capabilities::ResourceSubscribeNotAvailable.new(message: message)
        end
      end

      def reset_content!
        @content = nil
        @content_response = nil
        @content_expires_at = nil
      end

      def include(chat, **args)
        message = RubyLLM::Message.new(
          role: "user",
          content: to_content(**args)
        )

        chat.add_message(message)
      end

      def to_content
        content = self.content
        case content_type
        when "text"
          MCP::Content.new(text: "#{name}: #{description}\n\n#{content}")
        when "blob"
          attachment = MCP::Attachment.new(content, mime_type)
          MCP::Content.new(text: "#{name}: #{description}", attachments: [attachment])
        end
      end

      def to_h
        {
          uri: @uri,
          name: @name,
          description: @description,
          mime_type: @mime_type,
          contented_loaded: content_loaded?,
          content: @content
        }
      end

      alias to_json to_h

      private

      def apply_cache_hint(value)
        ttl_ms = value["ttlMs"]
        cache_scope = value["cacheScope"]
        @cache_hint = { ttl_ms: ttl_ms, cache_scope: cache_scope }.compact.freeze
        return if ttl_ms.nil?

        @content_expires_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (ttl_ms.to_f / 1000)
      end

      def content_cache_expired?
        @content_expires_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @content_expires_at
      end

      def content_type
        return "text" if @content_response.nil?

        if @content_response.key?("blob") && !@content_response["blob"].nil?
          "blob"
        else
          "text"
        end
      end

      def read_response(uri: @uri)
        parsed = URI.parse(uri)
        case parsed.scheme
        when "http", "https"
          fetch_uri_content(uri)
        else # file:// or git://
          @adapter.resource_read(uri: uri)
        end
      end

      def fetch_uri_content(uri)
        response = HTTPX.get(uri)
        { "result" => { "contents" => [{ "text" => response.body }] } }
      end
    end
  end
end
