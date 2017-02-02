class ViewModel
  class DeserializeContext
    attr_accessor :updated_associations
    attr_reader :parent_context, :parent_viewmodel
    private :parent_context, :parent_viewmodel

    class Changes
      attr_reader :changed_attributes, :changed_associations, :deleted

      def initialize(changed_attributes: [], changed_associations: [], deleted: false)
        @changed_attributes   = changed_attributes
        @changed_associations = changed_associations
        @deleted              = deleted
      end

      def deleted?
        deleted
      end

      def contained_to?(associations: [], attributes: [])
        !deleted? &&
          changed_associations.all? { |assoc| associations.include?(assoc) } &&
          changed_attributes.all? { |attr| attributes.include?(attr) }
      end
    end

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
        copy.initialize_as_child(self, parent_viewmodel)
      end
    end

    protected

    def initialize_as_child(parent_context, parent_viewmodel)
      @parent_context   = parent_context
      @parent_viewmodel = parent_viewmodel
    end
  end
end
