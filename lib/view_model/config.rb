# frozen_string_literal: true

require 'safe_values'
require 'keyword_builder'

ViewModel::Config = Value.new(
  show_cause_in_error_view: false,
  debug_deserialization: false,
)

class ViewModel::Config
  def self.configure!(&block)
    if instance_variable_defined?(:@instance)
      raise ArgumentError.new('ViewModel library already configured')
    end

    builder = KeywordBuilder.create(self, constructor: :with)
    @instance = builder.build!(&block)
  end

  def self._option(opt)
    configure! unless instance_variable_defined?(:@instance)
    @instance[opt]
  end

  self.members.each do |opt|
    define_singleton_method(opt) { _option(opt) }
  end
end
