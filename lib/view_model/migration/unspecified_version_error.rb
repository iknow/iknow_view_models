# frozen_string_literal: true

class ViewModel::Migration::UnspecifiedVersionError < ViewModel::AbstractError
  attr_reader :vm_name, :version

  status 400

  def initialize(vm_name, version)
    @vm_name = vm_name
    @version = version
  end

  def detail
    "Provided view for #{vm_name} at version #{version} does not match request"
  end

  def meta
    {
      viewmodel: vm_name,
      version: version,
    }
  end
end
