require "iknow_view_models/version"
require "view_model"
require "view_model/controller"
require "view_model/active_record"
require "view_model/active_record/controller"
require "view_model/active_record/singular_nested_controller"
require "view_model/active_record/collection_nested_controller"

module IknowViewModels
end

require 'iknow_view_models/railtie' if defined?(Rails)
