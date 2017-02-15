require "view_model"

module ViewModel::Controller
  extend ActiveSupport::Concern

  included do
    rescue_from ViewModel::AbstractError, with: ->(ex) do
      render_errors(ex.view, ex.status)
    end
  end

  def render_viewmodel(viewmodel, status: nil, serialize_context: viewmodel.class.try(:new_serialize_context), &block)
    prerender = prerender_viewmodel(viewmodel, serialize_context: serialize_context, &block)
    finish_render_viewmodel(prerender, status: status)
  end

  def prerender_viewmodel(viewmodel, status: nil, serialize_context: viewmodel.class.try(:new_serialize_context))
    Jbuilder.encode do |json|
      json.data do
        ViewModel.serialize(viewmodel, json, serialize_context: serialize_context)
      end

      if serialize_context && serialize_context.has_references?
        json.references do
          serialize_context.serialize_references(json)
        end
      end

      yield(json) if block_given?
    end
  end

  def finish_render_viewmodel(pre_rendered, status: nil)
    render_json_string(pre_rendered, status: status)
  end

  def render_errors(error_views, status = 500)
    render_jbuilder(status: status) do |json|
      json.errors Array.wrap(error_views) do |error_view|
        ViewModel.serialize(error_view, json)
      end
    end
  end

  protected

  def parse_viewmodel_updates
    update_hash = _extract_update_data(params.fetch(:data))
    refs        = _extract_param_hash(params.fetch(:references, {}))

    return update_hash, refs
  end

  private

  def _extract_update_data(data)
    if data.is_a?(Array)
      if data.blank?
        raise ViewModel::Error.new(status: 400, detail: "No data submitted: #{data.inspect}")
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
      raise ViewModel::Error.new(status: 400, detail: "Invalid data submitted, expected hash: #{data.inspect}")
    end
  end

  def render_jbuilder(status:)
    response = Jbuilder.encode do |json|
      yield json
    end

    render_json_string(response, status: status)
  end

  def render_json_string(response, status:)
    render(json: response, status: status)
  end
end
