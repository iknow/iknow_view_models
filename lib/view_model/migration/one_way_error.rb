# frozen_string_literal: true

class ViewModel::Migration::OneWayError < ViewModel::AbstractError
  attr_reader :vm_name, :direction

  status 400

  def initialize(vm_name, direction)
    @vm_name = vm_name
    @direction = direction
    super()
  end

  def detail
    "One way migration for #{vm_name} cannot be migrated #{direction}"
  end

  def meta
    {
      viewmodel: vm_name,
      direction: direction,
    }
  end
end
