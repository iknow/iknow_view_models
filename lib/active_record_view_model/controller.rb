require 'active_record_view_model/controller_base'
require 'active_record_view_model/nested_controller'

# Controller for accessing an ActiveRecordViewModel
# Provides for the following routes:
# GET    /models      #index
# POST   /models      #create or update (possibly multiple)
# GET    /models/:id  #show
# DELETE /models/:id  #destroy

module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
    delegate :viewmodel, to: :class
  end

  def show(scope: nil)
    context = serialize_view_context
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, scope: scope, serialize_context: context)
      render_viewmodel(view, serialize_context: context)
    end
  end

  def index(scope: nil)
    context = serialize_view_context
    viewmodel.transaction do
      views = viewmodel.load(scope: scope, serialize_context: context)
      render_viewmodel(views, serialize_context: context)
    end
  end

  def create
    update_hash, refs = parse_viewmodel_updates

    viewmodel.transaction do
      view = viewmodel.deserialize_from_view(update_hash, references: refs, deserialize_context: deserialize_view_context)
      render_viewmodel(view, serialize_context: serialize_view_context)
    end
  end

  def destroy
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, eager_include: false, serialize_context: serialize_view_context)
      view.destroy!(deserialize_context: deserialize_view_context)
    end
    render_viewmodel(nil)
  end

  protected

  def deserialize_view_context
    viewmodel.new_deserialize_context
  end

  def serialize_view_context
    viewmodel.new_serialize_context
  end

  private

  def viewmodel_id
    parse_integer_param(:id)
  end

  def parse_viewmodel_updates
    update_hash = params[:data]
    refs = params[:references]

    # Type-check incoming data
    unless _valid_update_hash?(update_hash)
      raise ActiveRecordViewModel::ControllerBase::BadRequest.new('Empty or invalid data submitted')
    end

    unless _valid_references?(refs)
      raise ActiveRecordViewModel::ControllerBase::BadRequest.new('Invalid references submitted')
    end

    # Normalize
    refs ||= {}

    return update_hash, refs
  end

  def _valid_update_hash?(update_hash)
    update_hash.is_a?(Hash) || (update_hash.is_a?(Array) && update_hash.all? { |el| el.is_a?(Hash) })
  end

  def _valid_references?(refs)
    !refs.present? || refs.is_a?(Hash)
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
