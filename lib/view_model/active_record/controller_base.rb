# frozen_string_literal: true

require 'iknow_params'

module ViewModel::ActiveRecord::ControllerBase
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

  def new_deserialize_context(viewmodel_class: self.viewmodel_class, access_control: self.access_control.new, **args)
    viewmodel_class.new_deserialize_context(access_control: access_control, **args)
  end

  def new_serialize_context(viewmodel_class: self.viewmodel_class, access_control: self.access_control.new, **args)
    viewmodel_class.new_serialize_context(access_control: access_control, **args)
  end

  class_methods do
    def viewmodel_class
      unless instance_variable_defined?(:@viewmodel_class)
        # try to autodetect the viewmodel based on our name
        if (match = /(.*)Controller$/.match(self.name))
          self.viewmodel_name = match[1].singularize
        else
          raise ArgumentError.new("Could not auto-determine ViewModel from Controller name '#{self.name}'")
        end
      end
      @viewmodel_class
    end

    def access_control
      unless instance_variable_defined?(:@access_control)
        raise ArgumentError.new("AccessControl instance not set for Controller '#{self.name}'")
      end

      @access_control
    end

    def model_class
      viewmodel_class.model_class
    end

    protected

    def viewmodel_name=(name)
      self.viewmodel_class = ViewModel::Registry.for_view_name(name)
    end

    def viewmodel_class=(type)
      if instance_variable_defined?(:@viewmodel_class)
        raise ArgumentError.new("ViewModel class for Controller '#{self.name}' already set")
      end

      unless type < ViewModel
        raise ArgumentError.new("'#{type.inspect}' is not a valid ViewModel")
      end

      @viewmodel_class = type
    end

    def access_control=(access_control)
      if instance_variable_defined?(:@access_control)
        raise ArgumentError.new("AccessControl class for Controller '#{self.name}' already set")
      end

      unless access_control.is_a?(Class) && access_control < ViewModel::AccessControl
        raise ArgumentError.new("'#{access_control.inspect}' is not a valid AccessControl")
      end

      @access_control = access_control
    end
  end

  def viewmodel_class
    self.class.viewmodel_class
  end

  def model_class
    self.class.model_class
  end

  def access_control
    self.class.access_control
  end
end

module ActionDispatch
  module Routing
    class Mapper
      module Resources
        def arvm_resources(resource_name, options = {}, &block)
          except             = options.delete(:except) { [] }
          add_shallow_routes = options.delete(:add_shallow_routes) { true }
          defaults           = options.delete(:defaults) { {} }

          nested = shallow_nesting_depth > 0

          association_name = options.delete(:association_name) { resource_name.to_s }
          owner_viewmodel  = options.delete(:owner_viewmodel) do
            if nested
              parent_resource.name.to_s.singularize.camelize
            end
          end

          defaults = {
            association_name: association_name,
            owner_viewmodel: owner_viewmodel,
          }.merge(defaults)

          only_routes = []
          only_routes += [:create] unless nested
          only_routes += [:show, :destroy] if add_shallow_routes
          only_routes -= except

          # Bulk replace
          if nested && !except.include?(:replace_bulk)
            collection do
              post resource_name, controller: resource_name, action: :replace_bulk, as: nil, defaults: defaults
            end
          end

          resources resource_name, shallow: true, only: only_routes, defaults: defaults, **options do
            instance_eval(&block) if block_given?

            if nested
              # Nested controllers also get :append and :disassociate, and alias a top level create.
              collection do
                name_route = { as: '' } # Only one route may take the name
                get('',    action: :index_associated, **name_route.extract!(:as)) unless except.include?(:index)
                put('',    action: :append,           **name_route.extract!(:as)) unless except.include?(:append)
                post('',   action: :replace,          **name_route.extract!(:as)) unless except.include?(:replace)
                delete('', action: :disassociate_all, **name_route.extract!(:as)) unless except.include?(:disassociate_all)
              end

              scope shallow: false do
                member do
                  delete '', action: :disassociate, as: '' unless except.include?(:disassociate)
                end
              end

              # Add top level `create` route to manipulate existing viewmodels
              # without providing parent context
              shallow_scope do
                collection do
                  name_route = { as: '' } # Only one route may take the name
                  post('', action: :create, **name_route.extract!(:as)) unless except.include?(:create) || !add_shallow_routes
                  get('',  action: :index,  **name_route.extract!(:as)) unless except.include?(:index)  || !add_shallow_routes
                  delete('', action: :destroy, as: :bulk_delete) unless except.include?(:destroy) || !add_shallow_routes
                end
              end
            else
              collection do
                get('', action: :index, as: '') unless except.include?(:index)
                delete('', action: :destroy, as: :bulk_delete) unless except.include?(:destroy)
              end
            end
          end
        end

        def arvm_resource(resource_name, options = {}, &block)
          except             = options.delete(:except) { [] }
          add_shallow_routes = options.delete(:add_shallow_routes) { true }
          defaults           = options.delete(:defaults) { {} }

          only_routes = []
          nested = shallow_nesting_depth > 0

          association_name = options.delete(:association_name) { resource_name.to_s }
          owner_viewmodel  = options.delete(:owner_viewmodel) do
            if nested
              parent_resource.name.to_s.singularize.camelize
            end
          end

          defaults = {
            association_name: association_name,
            owner_viewmodel: owner_viewmodel,
          }.merge(defaults)

          if nested && !except.include?(:create_associated_bulk)
            collection do
              post resource_name, controller: resource_name, action: :create_associated_bulk, as: nil, defaults: defaults
            end
          end

          resource resource_name, shallow: true, only: only_routes, defaults: defaults, **options do
            instance_eval(&block) if block_given?

            name_route = { as: '' } # Only one route may take the name

            if nested
              post('',   action: :create_associated,  **name_route.extract!(:as)) unless except.include?(:create)
              get('',    action: :show_associated,    **name_route.extract!(:as)) unless except.include?(:show)
              delete('', action: :destroy_associated, **name_route.extract!(:as)) unless except.include?(:destroy)
            else
              post('',   action: :create,  **name_route.extract!(:as)) unless except.include?(:create)
              get('',    action: :show,    **name_route.extract!(:as)) unless except.include?(:show)
              delete('', action: :destroy, **name_route.extract!(:as)) unless except.include?(:destroy)
            end
          end

          # singularly nested resources provide collection accessors at the top level
          if nested && add_shallow_routes
            resources resource_name.to_s.pluralize, shallow: true, only: [:show, :destroy] - except do
              shallow_scope do
                collection do
                  name_route = { as: '' } # Only one route may take the name
                  post('', action: :create, **name_route.extract!(:as)) unless except.include?(:create)
                  get('',  action: :index,  **name_route.extract!(:as)) unless except.include?(:index)
                end
              end
            end
          end
        end
      end
    end
  end
end
