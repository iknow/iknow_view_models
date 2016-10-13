class ViewModel
  # Key to identify a viewmodel with some kind of inherent ID (e.g. an ActiveRecordViewModel)
  class Reference
    attr_accessor :viewmodel_class, :model_id

    def initialize(viewmodel_class, model_id)
      @viewmodel_class = viewmodel_class
      @model_id        = model_id
    end

    def to_s
      "'#{viewmodel_class.view_name}(#{model_id})'"
    end

    def ==(other)
      other.class             == self.class &&
        other.viewmodel_class == viewmodel_class &&
        other.model_id        == model_id
    end

    alias :eql? :==

    def hash
      [viewmodel_class, model_id].hash
    end
  end
end
