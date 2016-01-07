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
      def render_viewmodel(viewmodel, status: nil, **options)
        response = Jbuilder.encode do |json|
          ViewModel.serialize(viewmodel, json, **options)
        end

        render(json: response, status: status)
      end
    end
  end
end
