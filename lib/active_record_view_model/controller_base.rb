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

  protected

  def parse_viewmodel_updates
    update_hash = _extract_update_data(params.fetch(:data))
    refs        = _extract_param_hash(params.fetch(:references, {}))

    return update_hash, refs
  end

  def _extract_update_data(data)
    if data.is_a?(Array)
      data.map { |el| _extract_param_hash(el) }
    else
      _extract_param_hash(data)
    end
  end

  def _extract_param_hash(data)
    case data
    when Hash, nil
      data
    when ActionController::Parameters
      data.to_unsafe_h
    else
      raise ActiveRecordViewModel::ControllerBase::BadRequest.new('Invalid data submitted, expected hash: #{data.inspect}')
    end
  end

  protected

  def deserialize_view_context(*args)
    viewmodel.new_deserialize_context(*args)
  end

  def serialize_view_context(*args)
    viewmodel.new_serialize_context(*args)
  end

  class_methods do
    def viewmodel
      unless instance_variable_defined?(:@viewmodel)
        # try to autodetect the viewmodel based on our name
        if (match = /(.*)Controller$/.match(self.name))
          self.viewmodel_name = match[1].singularize
        else
          raise ArgumentError.new("Could not auto-determine ViewModel from Controller name '#{self.name}'") if match.nil?
        end
      end
      @viewmodel
    end

    protected

    def viewmodel_name=(name)
      self.viewmodel = ActiveRecordViewModel.for_view_name(name)
    end

    def viewmodel=(type)
      if instance_variable_defined?(:@viewmodel)
        raise ArgumentError.new("ViewModel class for Controller '#{self.name}' already set")
      end

      unless type < ActiveRecordViewModel
        raise ArgumentError.new("'#{type.inspect}' is not a valid ActiveRecordViewModel")
      end
      @viewmodel = type
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

module ActionDispatch
  module Routing
    class Mapper
      module Resources
        def arvm_resources(resource_name, options = {}, &block)
          except = options[:except] || []
          only_routes = [:index, :show, :destroy, :create] - except

          resources resource_name, shallow: true, only: only_routes do
            instance_eval(&block) if block_given?

            if shallow_nesting_depth > 1
              # Nested controllers also get :append and :disassociate, and alias a top level create.
              collection do
                put    '', action: :append           unless except.include?(:append)
                delete '', action: :disassociate_all unless except.include?(:disassociate_all)
              end

              scope shallow: false do
                delete '', action: :disassociate     unless except.include?(:disassociate)
              end

              member do
                post '', action: :create unless except.include?(:create)
              end

            end
          end
        end

        def arvm_resource(resource_name, options = {}, &block)
          except = options[:except] || []
          only_routes = [:show, :destroy, :create] - except
          is_shallow = false
          resource resource_name, shallow: true, only: only_routes do
            is_shallow = shallow_nesting_depth > 1
            instance_eval(&block) if block_given?
          end

          # nested singular resources provide collection accessors at the top level
          if is_shallow
            resources resource_name.to_s.pluralize, shallow: true, only: [:show, :destroy] - except do
              member do
                post '', action: :create unless except.include?(:create)
              end
            end
          end
        end
      end
    end
  end
end
