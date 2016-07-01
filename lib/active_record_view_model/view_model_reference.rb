# Key for deferred resolution of an AR model
ActiveRecordViewModel::ViewModelReference = Struct.new(:viewmodel_class, :model_id) do
  class << self
    def from_viewmodel(vm)
      self.new(vm.class, vm.id)
    end
  end

  def to_s
    "'#{viewmodel_class.view_name}(#{model_id})'"
  end
end
