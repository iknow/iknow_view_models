# frozen_string_literal: true

require 'view_model'
require 'oj'

module ViewModel::Controller
  extend ActiveSupport::Concern

  included do
    rescue_from ViewModel::AbstractError, with: ->(ex) do
      render_error(ex.view, ex.status)
    end
  end

  def render_viewmodel(viewmodel, status: nil, serialize_context: viewmodel.class.try(:new_serialize_context), &block)
    prerender = prerender_viewmodel(viewmodel, serialize_context: serialize_context, &block)
    render_json_string(prerender, status: status)
  end

  # Render viewmodel(s) to a JSON API response as a String
  def prerender_viewmodel(viewmodel, status: nil, serialize_context: viewmodel.class.try(:new_serialize_context))
    encode_jbuilder do |json|
      json.data do
        ViewModel.serialize(viewmodel, json, serialize_context: serialize_context)
      end

      yield(json, serialize_context: serialize_context) if block_given?

      if serialize_context && serialize_context.has_references?
        json.references do
          serialize_context.serialize_references(json)
        end
      end
    end
  end

  # Render an arbitrarily nested tree of hashes and arrays with pre-rendered
  # JSON string terminals. Useful for rendering cached views without parsing
  # then re-serializing the cached JSON.
  def render_json_view(json_view, json_references: {}, status: nil, serialize_context: viewmodel.class.try(:new_serialize_context), &block)
    prerender = prerender_json_view(json_view, json_references: json_references, serialize_context: serialize_context, &block)
    render_json_string(prerender, status: status)
  end

  def prerender_json_view(json_view, json_references: {}, serialize_context: viewmodel.class.try(:new_serialize_context))
    json_view = wrap_json_view(json_view)
    json_references = wrap_json_view(json_references)

    encode_jbuilder do |json|
      json.data json_view

      if block_given?
        yield(json, serialize_context: serialize_context)

        if serialize_context && serialize_context.has_references?
          # The block contributed references: we serialize them and then merge
          # them together with the json references, with the json references
          # taking priority
          block_references = serialize_context.serialize_references_to_hash
          json_references = block_references.merge(json_references)
        end
      end

      if json_references.present?
        json.references do
          json_references.sort.each do |key, value|
            json.set!(key, value)
          end
        end
      end
    end
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
    data_param = params.fetch(:data) do
      raise ViewModel::Error.new(status: 400, detail: "Missing 'data' parameter")
    end
    refs_param = params.fetch(:references, {})

    update_hash = _extract_update_data(data_param)
    refs        = _extract_param_hash(refs_param)

    return update_hash, refs
  end

  def parse_bulk_update
    data, references = parse_viewmodel_updates

    ViewModel::Schemas.verify_schema!(ViewModel::Schemas::BULK_UPDATE, data)

    updates_by_parent =
      data.fetch(ViewModel::BULK_UPDATES_ATTRIBUTE).each_with_object({}) do |parent_update, acc|
        parent_id = parent_update.fetch(ViewModel::ID_ATTRIBUTE)
        update    = parent_update.fetch(ViewModel::BULK_UPDATE_ATTRIBUTE)

        acc[parent_id] = update
      end

    return updates_by_parent, references
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

  def encode_jbuilder
    builder = Jbuilder.new do |json|
      yield json
    end

    ViewModel.encode_json(builder.attributes!)
  end

  def render_jbuilder(status:)
    response = encode_jbuilder do |json|
      yield json
    end

    render_json_string(response, status: status)
  end

  def render_json_string(response, status: nil)
    render(json: response, status: status)
  end

  # Wrap raw JSON in such a way that MultiJSON knows to pass it through
  # untouched. Requires a MultiJson adapter other than ActiveSupport's
  # (modified) JsonGem.
  class CompiledJson
    def initialize(s)
      @s = s
    end

    def to_json(*_args)
      @s
    end

    def to_s
      @s
    end

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
