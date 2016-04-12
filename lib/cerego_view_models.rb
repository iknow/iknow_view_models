require "cerego_view_models/version"
require "view_model"
require "active_record_view_model"
require "active_record_view_model/controller"

module CeregoViewModels
  # expects a class that defines a "render" method
  # accepting json as a key like ActionController::Base
  # defines klass#render_view_model on the class
  def self.renderable!(klass)
    klass.class_eval do
      def render_viewmodel(viewmodel, status: nil, view_context: viewmodel.default_context)
        response = Jbuilder.encode do |json|
          ViewModel.serialize(viewmodel, json, view_context: view_context)
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
