class ViewModel::Record::AttributeData
  attr_reader :attribute_viewmodel

  def initialize(attribute_viewmodel, optional)
    @attribute_viewmodel = attribute_viewmodel
    @optional = optional
  end

  def optional?
    @optional
  end
end
