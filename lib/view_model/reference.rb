class ViewModel
  # Key to identify a viewmodel with some kind of inherent ID (e.g. an ActiveRecordViewModel)
  Reference = Struct.new(:viewmodel_class, :model_id) do
    class << self
      def from_viewmodel(vm)
        self.new(vm.class, vm.try(&:id))
      end
    end

    def to_s
      "'#{viewmodel_class.view_name}(#{model_id})'"
    end
  end

end
