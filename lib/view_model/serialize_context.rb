# frozen_string_literal: true

require 'active_support/core_ext'
require 'view_model/traversal_context'

class ViewModel::SerializeContext < ViewModel::TraversalContext
  class SharedContext < ViewModel::TraversalContext::SharedContext
    attr_reader :references, :flatten_references

    def initialize(flatten_references: false, **rest)
      super(**rest)
      @references         = ViewModel::References.new
      @flatten_references = flatten_references
    end
  end

  def self.shared_context_class
    SharedContext
  end

  delegate :references, :flatten_references, to: :shared_context
  delegate :add_reference, :has_references?, to: :references

  # Return viewmodels referenced during serialization and clear @references.
  def extract_referenced_views!
    refs = references.each.to_h
    references.clear!
    refs
  end

  def serialize_references(json)
    reference_context = self.for_references

    # References should be serialized in a stable order to improve caching via
    # naive response hash.

    serialized_refs = {}

    while references.present?
      extract_referenced_views!.each do |ref, value|
        unless serialized_refs.has_key?(ref)
          serialized_refs[ref] = Jbuilder.new do |j|
            ViewModel.serialize(value, j, serialize_context: reference_context)
          end
        end
      end
    end

    serialized_refs.sort.each do |ref, value|
      json.set!(ref, value)
    end
  end

  def serialize_references_to_hash
    Jbuilder.new { |json| serialize_references(json) }.attributes!
  end
end
