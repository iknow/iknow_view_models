require "iknow_params/parser"

class ActiveRecordViewModel
module ControllerBase
  extend ActiveSupport::Concern
  include IknowParams::Parser

  class RenderError < StandardError
    attr_accessor :code
    def initialize(msg, code)
      super(msg)
      self.code = code
    end
  end

  class BadRequest < RenderError
    def initialize(msg)
      super(msg, 400)
    end
  end

  included do
    CeregoViewModels.renderable!(self)
    delegate :viewmodel, to: 'self.class'

    rescue_from StandardError,                                with: :render_error
    rescue_from RenderError,                                  with: ->(ex){ render_error(ex, ex.code) }

    rescue_from ActiveRecord::RecordNotFound,                 with: ->(ex){ render_error(ex, 404)}

    rescue_from ViewModel::DeserializationError,              with: ->(ex){ render_error(ex, 400)}
    rescue_from ViewModel::DeserializationError::Permissions, with: ->(ex){ render_error(ex, 403)}

    rescue_from ViewModel::SerializationError,                with: ->(ex){ render_error(ex, 400)}
    rescue_from ViewModel::SerializationError::Permissions,   with: ->(ex){ render_error(ex, 403)}

    rescue_from IknowParams::Parser::ParseError,              with: ->(ex){ render_error(ex, 400)}
  end

end
end
