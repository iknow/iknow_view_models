require "iknow_params/parser"

class ViewModel::ActiveRecord
module ControllerBase
  extend ActiveSupport::Concern
  include IknowParams::Parser
  include ViewModel::Controller

  protected

  def parse_viewmodel_updates
    update_hash = _extract_update_data(params.fetch(:data))
    refs        = _extract_param_hash(params.fetch(:references, {}))

    return update_hash, refs
  end

  def _extract_update_data(data)
    if data.is_a?(Array)
      if data.blank?
        raise ViewModel::Controller::ApiErrorView.new(status: 400, detail: "No data submitted: #{data.inspect}").to_error
      end
      data.map { |el| _extract_param_hash(el) }
    else
      _extract_param_hash(data)
    end
  end

  def _extract_param_hash(data)
    case data
    when Hash
      data
    when ActionController::Parameters
      data.to_unsafe_h
    else
      raise ViewModel::Controller::ApiErrorView.new(status: 400, detail: "Invalid data submitted, expected hash: #{data.inspect}").to_error
    end
  end

  protected

  def new_deserialize_context(*args)
    viewmodel.new_deserialize_context(*args)
  end

  def new_serialize_context(*args)
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
      self.viewmodel = ViewModel::ActiveRecord.for_view_name(name)
    end

    def viewmodel=(type)
      if instance_variable_defined?(:@viewmodel)
        raise ArgumentError.new("ViewModel class for Controller '#{self.name}' already set")
      end

      unless type < ViewModel::ActiveRecord
        raise ArgumentError.new("'#{type.inspect}' is not a valid ViewModel::ActiveRecord")
      end
      @viewmodel = type
    end
  end

  included do
    delegate :viewmodel, to: 'self.class'

    rescue_from ViewModel::DeserializationError, with: ->(ex){ render_exception(ex, ex.http_status, metadata: ex.metadata) }
    rescue_from ViewModel::SerializationError,   with: ->(ex){ render_exception(ex, ex.http_status, metadata: ex.metadata) }
  end

end
end

module ActionDispatch
  module Routing
    class Mapper
      module Resources
        def arvm_resources(resource_name, options = {}, &block)
          except             = options.delete(:except){ [] }
          add_shallow_routes = options.delete(:add_shallow_routes){ true }

          only_routes  = [:index, :create]
          only_routes += [:show, :destroy] if add_shallow_routes
          only_routes -= except

          resources resource_name, shallow: true, only: only_routes, **options do
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

              # Add top level `create` route to manipulate existing viewmodels
              # without providing parent context
              shallow_scope do
                collection do
                  post '', action: :create unless except.include?(:create) || !add_shallow_routes
                end
              end

            end
          end
        end

        def arvm_resource(resource_name, options = {}, &block)
          except             = options.delete(:except){ [] }
          add_shallow_routes = options.delete(:add_shallow_routes){ true }

          only_routes = [:show, :destroy, :create] - except
          is_shallow = false
          resource resource_name, shallow: true, only: only_routes, **options do
            is_shallow = shallow_nesting_depth > 1
            instance_eval(&block) if block_given?
          end

          # nested singular resources provide collection accessors at the top level
          if is_shallow && add_shallow_routes
            resources resource_name.to_s.pluralize, shallow: true, only: [:show, :destroy] - except do
              shallow_scope do
                collection do
                  post '', action: :create unless except.include?(:create)
                end
              end
            end
          end
        end
      end
    end
  end
end
