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
      ref = @ref_by_value[value]

      unless ref.present?
        ref = new_ref!(value)
        @ref_by_value[value] = ref
        @value_by_ref[ref] = value
      end

      ref
    end

    def add_preserialized_reference(ref, literal_value)
      return ref if @value_by_ref.has_key?(ref)

      @ref_by_value[literal_value] = ref
      @value_by_ref[ref] = literal_value
      ref
    end

    def clear!
      @ref_by_value.clear
      @value_by_ref.clear
    end

    private

    # Ensure stable reference keys for the same (persisted) viewmodels. For
    # unpersisted viewmodels, use a counter to generate a reference key unique
    # to this serialization.
    def new_ref!(viewmodel)
      vm_ref = viewmodel.to_reference
      if vm_ref.model_id
        vm_ref.stable_reference
      else
        format('ref:i:%06<count>d', count: (@last_ref += 1))
      end
    end
  end
end
