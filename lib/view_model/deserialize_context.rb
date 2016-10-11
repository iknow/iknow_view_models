class ViewModel
  class DeserializeContext
    attr_accessor :updated_associations, :parent_ref

    def initialize(parent_ref: nil)
      self.parent_ref = parent_ref
    end

    def for_child(parent)
      self.dup.tap do |copy|
        copy.parent_ref = parent.to_reference
      end
    end
  end
end
