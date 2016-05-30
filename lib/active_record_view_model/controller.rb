require 'active_record_view_model/controller_base'

# Controller for accessing an ActiveRecordViewModel
# Provides for the following routes:
# POST   /models      #create -- create or update one or more models
# GET    /models      #index
# GET    /models/:id  #show
# DELETE /models/:id  #destroy

module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
    delegate :viewmodel, to: 'self.class'
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

    ser_context = serialize_view_context
    viewmodel.transaction do
      view = viewmodel.deserialize_from_view(update_hash, references: refs, deserialize_context: deserialize_view_context)
      ViewModel.preload_for_serialization(view, serialize_context: ser_context)
      render_viewmodel(view, serialize_context: ser_context)
    end
  end

  def destroy
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, eager_include: false, serialize_context: serialize_view_context)
      view.destroy!(deserialize_context: deserialize_view_context)
      render_viewmodel(nil)
    end
  end

  private

  def viewmodel_id
    parse_integer_param(:id)
  end

end
