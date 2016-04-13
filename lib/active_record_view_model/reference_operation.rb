class ActiveRecordViewModel::ReferenceOperation
  def initialize(model)
    @model = model
  end

  def run!(view_context:)
    @model
  end
end
