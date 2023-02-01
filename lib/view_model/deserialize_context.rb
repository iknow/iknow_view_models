# frozen_string_literal: true

require 'view_model/traversal_context'

class ViewModel::DeserializeContext < ViewModel::TraversalContext
  class SharedContext < ViewModel::TraversalContext::SharedContext
    def initialize(validate_deferred_constraints: true, **rest)
      super(**rest)
      @validate_deferred_constraints = validate_deferred_constraints
    end

    # Should deferred database constraints be checked via SET CONSTRAINTS
    # IMMEDIATE at the end of the deserialization operation
    def validate_deferred_constraints?
      @validate_deferred_constraints
    end
  end

  def self.shared_context_class
    SharedContext
  end

  delegate :validate_deferred_constraints?, to: :shared_context
end
