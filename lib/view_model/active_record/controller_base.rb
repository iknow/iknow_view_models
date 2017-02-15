require "iknow_params/parser"

class ViewModel::ActiveRecord
module ControllerBase
  extend ActiveSupport::Concern
  include IknowParams::Parser
  include ViewModel::Controller

  protected

  # Override (pre)render_viewmodel to use the default serialization context from this controller.
  def render_viewmodel(viewmodel, serialize_context: new_serialize_context, **args)
    super(viewmodel, serialize_context: serialize_context, **args)
  end

  def prerender_viewmodel(viewmodel, serialize_context: new_serialize_context, **args)
    super(viewmodel, serialize_context: serialize_context, **args)
  end

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
      self.viewmodel = ViewModel::Registry.for_view_name(name)
    end

    def viewmodel=(type)
      if instance_variable_defined?(:@viewmodel)
        raise ArgumentError.new("ViewModel class for Controller '#{self.name}' already set")
      end

      unless type < ViewModel
        raise ArgumentError.new("'#{type.inspect}' is not a valid ViewModel")
      end
      @viewmodel = type
    end
  end

  included do
    delegate :viewmodel, to: 'self.class'
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
                put    '', action: :append,  as: ''  unless except.include?(:append)
                post   '', action: :replace          unless except.include?(:replace)
                delete '', action: :disassociate_all unless except.include?(:disassociate_all)
              end

              scope shallow: false do
                delete '', action: :disassociate, as: '' unless except.include?(:disassociate)
              end

              # Add top level `create` route to manipulate existing viewmodels
              # without providing parent context
              shallow_scope do
                collection do
                  post '', action: :create, as: '' unless except.include?(:create) || !add_shallow_routes
                  get  '', action: :index          unless except.include?(:index)  || !add_shallow_routes
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
