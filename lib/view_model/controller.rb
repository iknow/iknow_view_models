# frozen_string_literal: true

require "view_model"

module ViewModel::Controller
  extend ActiveSupport::Concern

  included do
    rescue_from ViewModel::AbstractError, with: ->(ex) do
      render_error(ex.view, ex.status)
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

  # Render an arbitrarily nested tree of hashes and arrays with pre-rendered
  # JSON string terminals. Useful for rendering cached views without parsing
  # then re-serializing the cached JSON.
  def render_json_view(json_view, json_references: {}, status: nil)
    json_view = wrap_json_view(json_view)
    json_references = wrap_json_view(json_references)

    response = Jbuilder.encode do |json|
      json.data json_view
      if json_references.present?
        json.references do
          json_references.sort.each do |key, value|
            json.set!(key, value)
          end
        end
      end
      yield(json) if block_given?
    end

    render_json_string(response, status: status)
  end

  def render_error(error_view, status = 500)
    unless error_view.is_a?(ViewModel)
      raise "Expected ViewModel error view, received #{error_view.inspect}"
    end

    render_jbuilder(status: status) do |json|
      json.error do
        ctx = error_view.class.new_serialize_context(access_control: ViewModel::AccessControl::Open.new)
        ViewModel.serialize(error_view, json, serialize_context: ctx)
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

  # Wrap raw JSON in such a way that MultiJSON knows to pass it through
  # untouched. Requires a MultiJson adapter other than ActiveSupport's
  # (modified) JsonGem.
  class CompiledJson
    def initialize(s);  @s = s; end
    def to_json(*args); @s;     end
    def to_s;           @s;     end
    undef_method :as_json
  end

  # Traverse a tree and wrap all String terminals in CompiledJson
  def wrap_json_view(view)
    case view
    when Array
      view.map { |v| wrap_json_view(v) }
    when Hash
      view.transform_values { |v| wrap_json_view(v) }
    when String, Symbol
      CompiledJson.new(view)
    else
      view
    end
  end
end
