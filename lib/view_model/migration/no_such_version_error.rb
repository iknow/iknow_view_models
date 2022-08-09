# frozen_string_literal: true

class ViewModel::Migration::NoSuchVersionError < ViewModel::AbstractError
  attr_reader :vm_name, :version

  status 400
  code 'Migration.NoSuchVersionError'

  def initialize(viewmodel, version)
    @vm_name = viewmodel.view_name
    @version = version
    super()
  end

  def detail
    "No version found for #{vm_name} at version #{version}"
  end

  def meta
    {
      viewmodel: vm_name,
      version: version,
    }
  end
end
