class ViewModel::Record::AttributeData
  attr_reader :name, :attribute_viewmodel

  def initialize(name, attribute_viewmodel, optional, read_only, write_once)
    @name = name
    @attribute_viewmodel = attribute_viewmodel
    @optional = optional
    @read_only = read_only
    @write_once = write_once
  end

  def optional?
    @optional
  end

  def read_only?
    @read_only
  end

  def write_once?
    @write_once
  end

  def using_viewmodel?
    !@attribute_viewmodel.nil?
  end
end
