require 'active_record_view_model/controller_base'
require 'active_record_view_model/nested_controller'

# Controller for accessing an ActiveRecordViewModel
# Provides for the following routes:
# GET    /models      #index
# POST   /models      #create
# GET    /models/:id  #show
# PATCH  /models/:id  #update
# PUT    /models/:id  #update
# DELETE /models/:id  #destroy

module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
    delegate :viewmodel, to: :class
  end

  def show(scope: nil)
    view_context = serialize_view_context
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, scope: scope, view_context: view_context)
      render_viewmodel(view, view_context: view_context)
    end
  end

  def index(scope: nil)
    view_context = serialize_view_context
    viewmodel.transaction do
      views = viewmodel.load(scope: scope, view_context: view_context)
      render_viewmodel(views, view_context: view_context)
    end
  end

  def create
    deserialize(nil)
  end

  def update
    deserialize(viewmodel_id)
  end

  def destroy
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, eager_include: false, view_context: serialize_view_context)
      view.destroy!(view_context: deserialize_view_context)
    end
    render_viewmodel(nil)
  end

  protected

  def deserialize_view_context
    viewmodel.default_deserialize_context
  end

  def serialize_view_context
    viewmodel.default_serialize_context
  end

  private

  def viewmodel_id
    parse_integer_param(:id)
  end

  def deserialize(requested_id)
    update_hash = params[:data].to_h

    unless update_hash.is_a?(Hash)
      raise ActiveRecordViewModel::ControllerBase::BadRequest.new("Empty or invalid data submitted")
    end

    # TODO check type as well?

    if requested_id.present?
      if !update_hash.has_key?(ActiveRecordViewModel::ID_ATTRIBUTE)
        raise ActiveRecordViewModel::ControllerBase::BadRequest.new("Not an update action: provided data doesn't represent an existing object")
      elsif update_hash[ActiveRecordViewModel::ID_ATTRIBUTE] != requested_id
        raise ActiveRecordViewModel::ControllerBase::BadRequest.new("Invalid update action: provided data represents a different object")
      end
    elsif update_hash.has_key?(ActiveRecordViewModel::ID_ATTRIBUTE)
      raise ActiveRecordViewModel::ControllerBase::BadRequest.new("Not a create action: provided data represents an existing object")
    end

    viewmodel.transaction do
      view = viewmodel.deserialize_from_view(update_hash, view_context: deserialize_view_context)
      render_viewmodel(view, view_context: serialize_view_context)
    end
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

    def nested_in(owner, as:)
      include ActiveRecordViewModel::NestedController
      self.owner_viewmodel = ActiveRecordViewModel.for_view_name(owner.to_s.camelize)
      raise ArgumentError.new("Could not find owner ViewModel class '#{owner_name}'") if owner_viewmodel.nil?
      self.association_name = as
    end

    private

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
end
