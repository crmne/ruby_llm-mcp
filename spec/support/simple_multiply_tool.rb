# frozen_string_literal: true

# Simple test tool class using base RubyLLM::Parameter.
# RubyLLM 1 declares parameters with .param(desc:) and RubyLLM 2 with
# .parameter(description:), so use whichever the installed version provides.
class SimpleMultiplyTool < RubyLLM::Tool
  description "Multiply two numbers together"

  [[:x, "First number"], [:y, "Second number"]].each do |name, text|
    if respond_to?(:parameter)
      parameter name, type: :number, description: text, required: true
    else
      param name, type: :number, desc: text, required: true
    end
  end

  def execute(x:, y:) # rubocop:disable Naming/MethodParameterName
    (x * y).to_s
  end
end
