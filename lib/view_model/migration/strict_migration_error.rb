# frozen_string_literal: true

class ViewModel::Migration::StrictMigrationError < ViewModel::AbstractError
  attr_reader :vm_name

  status 400
  code 'Migration.StrictMigrationError'

  def initialize(vm_name)
    @vm_name = vm_name
    super()
  end

  def detail
    "No version was provided for the view #{vm_name}"
  end

  def meta
    {
      viewmodel: vm_name,
    }
  end
end
