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

  attr_reader :include, :prune

  def initialize(include: nil, prune: nil, **rest)
    super(**rest)
    @include = self.class.normalize_includes(include)
    @prune   = self.class.normalize_includes(prune)
  end

  def initialize_as_child(include:, prune:, **rest)
    super(**rest)
    @include = include
    @prune   = prune
  end

  def for_child(parent_viewmodel, association_name:, **rest)
    super(parent_viewmodel,
          association_name: association_name,
          include: @include.try { |i| i[association_name] },
          prune:   @prune.try   { |p| p[association_name] },
          **rest)
  end

  # Obtain a semi-independent context for serializing references: keep the same
  # shared context, but drop any tree location specific local context.
  def for_references
    self.class.new(shared_context: shared_context)
  end

  def includes_member?(member_name, default)
    member_name = member_name.to_s

    # Every node in the include tree is to be included
    included = @include.try { |is| is.has_key?(member_name) }
    # whereas only the leaves of the prune tree are to be removed
    pruned   = @prune.try { |ps| ps.fetch(member_name, :sentinel).nil? }

    (default || included) && !pruned
  end

  def add_includes(includes)
    return if includes.blank?
    @include ||= {}
    @include.deep_merge!(self.class.normalize_includes(includes))
  end

  def add_prunes(prunes)
    return if prunes.blank?
    @prune ||= {}
    @prune.deep_merge!(self.class.normalize_includes(prunes))
  end

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

  def self.normalize_includes(includes)
    case includes
    when Array
      includes.each_with_object({}) do |v, new_includes|
        new_includes.merge!(normalize_includes(v))
      end
    when Hash
      includes.each_with_object({}) do |(k,v), new_includes|
        new_includes[k.to_s] = normalize_includes(v)
      end
    when nil
      nil
    else
      { includes.to_s => nil }
    end
  end
end
