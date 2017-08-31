require 'view_model/traversal_context'

class ViewModel::DeserializeContext < ViewModel::TraversalContext
  class SharedContext < ViewModel::TraversalContext::SharedContext
    # During deserialization, collects a tree of viewmodel association names that
    # were updated. Used to ensure that updated associations are always included
    # in response serialization after deserialization, even if hidden by default.
    attr_accessor :updated_associations
  end

  def self.shared_context_class
    SharedContext
  end

  delegate :updated_associations, :"updated_associations=", to: :shared_context

  def initial_editability(view)
    shared_context.access_control.initial_editability(view, deserialize_context: self)
  end

  def editable!(view, initial_editability: nil, changes:)
    shared_context.access_control.editable!(view, initial_editability: initial_editability, deserialize_context: self, changes: changes)
  end
end
