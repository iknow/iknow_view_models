require "cerego_view_models/version"
require "view_model"
require "active_record_view_model"
require "active_record_view_model/controller"
require "active_record_view_model/singular_nested_controller"
require "active_record_view_model/collection_nested_controller"

module CeregoViewModels

  class ExceptionView < ViewModel
    attributes :exception, :status, :metadata

    def serialize_view(json, serialize_context: nil)
      json.errors [exception] do |e|
        json.status status
        json.detail exception.message

        json.metadata do
          ViewModel.serialize(metadata, json, serialize_context: serialize_context)
        end

        if Rails.env != 'production'
          json.set! :class, exception.class.name
          json.backtrace exception.backtrace
        end
      end
    end
  end


  # expects a class that defines a "render" method
  # accepting json as a key like ActionController::Base
  # defines klass#render_view_model on the class

  def self.renderable!(klass)
    klass.class_eval do
      def render_viewmodel(viewmodel, status: nil, serialize_context: viewmodel.class.try(:new_deserialize_context))
        render_jbuilder(status: status) do |json|
          json.data do
            ViewModel.serialize(viewmodel, json, serialize_context: serialize_context)
          end

          if serialize_context && serialize_context.has_references?
            json.references do
              serialize_context.serialize_references(json)
            end
          end
        end
      end

      def render_error(exception, status = 500, metadata: {})
        render_jbuilder(status: status) do |json|
          ViewModel.serialize(ExceptionView.new(exception, status, metadata), json)
        end
      end

      private

      def render_jbuilder(status:)
        response = Jbuilder.encode do |json|
          yield json
        end

        ## jbuilder prevents this from working
        ##  - https://github.com/rails/jbuilder/issues/317
        ##  - https://github.com/rails/rails/issues/23923

        # render(json: response, status: status)

        render(plain: response, status: status, content_type: 'application/json')
      end
    end
  end
end
