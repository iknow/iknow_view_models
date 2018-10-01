# frozen_string_literal: true

class IknowViewModels::Railtie < Rails::Railtie
  # On code reload, clear registered viewmodels that are no longer present.
  config.to_prepare do
    ViewModel::Registry.clear_removed_classes!
  end
end
