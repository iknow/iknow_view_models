# frozen_string_literal: true

require 'view_model/traversal_context'

class ViewModel::DeserializeContext < ViewModel::TraversalContext
  class SharedContext < ViewModel::TraversalContext::SharedContext
  end

  def self.shared_context_class
    SharedContext
  end
end
