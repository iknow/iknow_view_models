class ViewModel::Record::AttributeData
  attr_reader :attribute_viewmodel

  def initialize(attribute_viewmodel, optional, read_only)
    @attribute_viewmodel = attribute_viewmodel
    @optional = optional
    @read_only = read_only
  end

  def optional?
    @optional
  end

  def read_only?
    @read_only
  end
end
