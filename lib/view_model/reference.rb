# frozen_string_literal: true

class ViewModel
  # Key to identify a viewmodel with some kind of inherent ID (e.g. an ViewModel::ActiveRecord)
  class Reference
    attr_accessor :viewmodel_class, :model_id

    def initialize(viewmodel_class, model_id)
      @viewmodel_class = viewmodel_class
      @model_id        = model_id
    end

    def to_s
      "'#{viewmodel_class.view_name}(id=#{model_id})'"
    end

    def inspect
      "<Ref:#{self}>"
    end

    def ==(other)
      other.class             == self.class &&
        other.viewmodel_class == viewmodel_class &&
        other.model_id        == model_id
    end

    alias eql? ==

    def hash
      [viewmodel_class, model_id].hash
    end

    # Generate a stable reference key for this viewmodel using type name and id
    def stable_reference
      raise RuntimeError.new('Model id required to generate a stable reference') unless model_id

      hash = Digest::SHA256.base64digest("#{viewmodel_class.name}.#{model_id}")
      "ref:h:#{hash}"
    end
  end
end
