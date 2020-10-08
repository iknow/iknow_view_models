# frozen_string_literal: true

class ViewModel
  # A bucket for configuration, used for serializing and deserializing.
  class References
    delegate :each, :size, :present?, to: :@value_by_ref

    def initialize
      @last_ref = 0
      @ref_by_value = {}
      @value_by_ref = {}
    end

    def has_references?
      @ref_by_value.present?
    end

    # Takes a reference to a thing that is to be shared, and returns the id
    # under which the data is stored. If the data is not present, will compute
    # it by calling the given block.
    def add_reference(value)
      if (ref = @ref_by_value[value]).present?
        ref
      else
        ref = new_ref!(value)
        @ref_by_value[value] = ref
        @value_by_ref[ref] = value
        ref
      end
    end

    def clear!
      @ref_by_value.clear
      @value_by_ref.clear
    end

    private

    # Ensure stable reference ids for the same (persisted) viewmodels.
    def new_ref!(viewmodel)
      vm_ref = viewmodel.to_reference
      if vm_ref.model_id
        hash = Digest::SHA256.base64digest("#{vm_ref.viewmodel_class.name}.#{vm_ref.model_id}")
        "ref:h:#{hash}"
      else
        'ref:i:%06d' % (@last_ref += 1)
      end
    end
  end
end
