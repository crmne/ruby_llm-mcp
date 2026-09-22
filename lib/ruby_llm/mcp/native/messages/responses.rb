# frozen_string_literal: true

module RubyLLM
  module MCP
    module Native
      module Messages
        # Response message builders
        # Responses are sent in reply to requests from the server
        module Responses
          extend Helpers

          # RubyLLM 2 finish reasons mapped to the stop reasons MCP defines.
          FINISH_REASON_TO_STOP_REASON = {
            stop: "endTurn",
            max_tokens: "maxTokens",
            tool_calls: "toolUse",
            content_filter: "contentFilter"
          }.freeze

          module_function

          def ping(id:)
            {
              jsonrpc: JSONRPC_VERSION,
              id: id,
              result: {}
            }
          end

          def roots_list(id:, roots_paths:)
            roots_response = roots_paths.map do |path|
              {
                uri: "file://#{path}",
                name: File.basename(path, ".*")
              }
            end

            {
              jsonrpc: JSONRPC_VERSION,
              id: id,
              result: {
                roots: roots_response
              }
            }
          end

          def result(id:, value:)
            {
              jsonrpc: JSONRPC_VERSION,
              id: id,
              result: value
            }
          end

          def sampling_create_message(id:, message:, model:, protocol_version: nil)
            stop_reason = if message.respond_to?(:finish_reason) && message.finish_reason
                            finish_reason_to_stop_reason(message.finish_reason)
                          elsif message.respond_to?(:stop_reason) && message.stop_reason
                            snake_to_camel(message.stop_reason)
                          else
                            "endTurn"
                          end

            {
              jsonrpc: JSONRPC_VERSION,
              id: id,
              result: {
                role: message.role,
                content: format_message_content(message, protocol_version: protocol_version),
                model: model,
                stopReason: stop_reason
              }
            }
          end

          def elicitation(id:, action:, content: nil)
            {
              jsonrpc: JSONRPC_VERSION,
              id: id,
              result: {
                action: action,
                content: content
              }.compact
            }
          end

          def error(id:, message:, code: JsonRpc::ErrorCodes::SERVER_ERROR, data: nil)
            error_object = {
              code: code,
              message: message
            }
            error_object[:data] = data if data

            {
              jsonrpc: JSONRPC_VERSION,
              id: id,
              error: error_object
            }
          end

          def format_message_content(message, protocol_version: nil)
            content = message.content
            attachments = if !defined?(RubyLLM::Content) && message.is_a?(RubyLLM::Message)
                            message.attachments
                          else
                            []
                          end
            if defined?(RubyLLM::Content) && content.is_a?(RubyLLM::Content)
              attachments = content.attachments
              content = content.text
            end

            blocks = sampling_content_blocks(content, attachments)
            if blocks.empty?
              { type: "text", text: content }
            elsif blocks.length > 1 && Native::Protocol.sampling_content_array_supported?(protocol_version)
              blocks
            else
              # Before 2025-11-25 a CreateMessageResult carries exactly one content
              # block, so older tracks receive only the first block.
              blocks.first
            end
          end
          private_class_method :format_message_content

          # One block for non-empty text followed by one per image or audio
          # attachment, the only attachment kinds MCP sampling content allows.
          def sampling_content_blocks(text, attachments)
            blocks = text.to_s.empty? ? [] : [{ type: "text", text: text }]

            attachments.each do |attachment|
              case attachment.type
              when :image, :audio
                blocks << { type: attachment.type, data: attachment.encoded, mimeType: attachment.mime_type }
              else
                RubyLLM::MCP.logger.warn(
                  "Skipping sampling attachment of unsupported type #{attachment.type} (#{attachment.mime_type})"
                )
              end
            end

            blocks
          end
          private_class_method :sampling_content_blocks

          def finish_reason_to_stop_reason(reason)
            # Unknown reasons are camelized as a best effort; MCP permits any string.
            FINISH_REASON_TO_STOP_REASON.fetch(reason.to_sym) { snake_to_camel(reason.to_s) }
          end
          private_class_method :finish_reason_to_stop_reason

          def snake_to_camel(str)
            parts = str.split("_")
            parts.first + parts[1..].map(&:capitalize).join
          end
          private_class_method :snake_to_camel
        end
      end
    end
  end
end
