class ViewModel
  # A bucket for configuration, used for serializing and deserializing.
  class References
    delegate :each, :size, to: :@value_by_ref

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
        ref = new_ref!
        @ref_by_value[value] = ref
        @value_by_ref[ref] = value
        ref
      end
    end

    private

    def new_ref!
      'ref%06d' % (@last_ref += 1)
    end
  end
end
