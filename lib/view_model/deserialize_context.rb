class ViewModel
  class DeserializeContext
    attr_accessor :updated_associations, :parent_context, :parent_viewmodel

    def initialize(*)
    end

    def parent(idx = 0)
      if idx == 0
        parent_viewmodel
      else
        parent_context&.parent(idx - 1)
      end
    end

    def parent_ref(idx = 0)
      parent(idx)&.to_reference
    end

    def for_child(parent_viewmodel)
      self.dup.tap do |copy|
        copy.parent_context   = self
        copy.parent_viewmodel = parent_viewmodel
      end
    end

    private :parent_context, :parent_viewmodel
  end
end
