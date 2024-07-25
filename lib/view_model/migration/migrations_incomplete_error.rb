# frozen_string_literal: true

class ViewModel::Migration::MigrationsIncompleteError < ViewModel::AbstractError
  attr_reader :vm_name, :version

  status 400
  code 'Migration.MigrationsIncomplete'

  def initialize(viewmodel, version)
    @vm_name = viewmodel.view_name
    @version = version
    super()
  end

  def detail
    "Viewmodel '#{vm_name}' neither defines a migration reaching client version #{version} nor explicitly excludes it"
  end

  def meta
    {
      viewmodel: vm_name,
      version: version,
    }
  end
end
