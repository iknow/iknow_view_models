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

    def remove_type_context(type)
      contents = @type_contexts.delete(type)
      unless contents
        raise new ArgumentError.new("Attempt to remove non-existing type context for type '#{type}'")
      end
    end

    def type_context(type)
      unless @type_contexts.has_key?(type)
        @type_contexts[type] = yield if block_given?
      end
      @type_contexts.fetch(type)
    end

    protected

    def initialize_as_child(parent_context, parent_viewmodel)
      @parent_context   = parent_context
      @parent_viewmodel = parent_viewmodel
    end
  end
end
