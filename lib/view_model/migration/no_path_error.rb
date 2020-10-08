# frozen_string_literal: true

class ViewModel::Migration::NoPathError < ViewModel::AbstractError
  attr_reader :vm_name, :from, :to

  status 400

  def initialize(viewmodel, from, to)
    @vm_name = viewmodel.view_name
    @from = from
    @to = to
  end

  def detail
    "No migration path for #{vm_name} from #{from} to #{to}"
  end

  def meta
    {
      viewmodel: vm_name,
      from: from,
      to: to,
    }
  end
end
