class ViewModel
  class DeserializeContext
    attr_accessor :updated_associations
    attr_reader :parent_context, :parent_viewmodel
    private :parent_context, :parent_viewmodel

    def initialize(*)
      @type_contexts = {}
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
        copy.initialize_as_child(self, parent_viewmodel)
      end
    end

    def with_type_context(type, context)
      self.dup.tap do |copy|
        copy.set_type_context(type, context)
      end
    end

    protected

    def initialize_copy
      @type_contexts = @type_contexts.dup
    end

    def initialize_as_child(parent_context, parent_viewmodel)
      @parent_context   = parent_context
      @parent_viewmodel = parent_viewmodel
    end

    def set_type_context(type, context)
      @type_contexts[type] = context
    end
  end
end
