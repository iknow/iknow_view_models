class ViewModel
  class SerializeContext
    delegate :add_reference, :has_references?, to: :@references
    attr_accessor :include, :prune, :flatten_references

    def normalize_includes(includes)
      case includes
      when Array
        includes.each_with_object({}) do |v, new_includes|
          new_includes[v.to_s] = nil
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

    def initialize(include: nil, prune: nil, flatten_references: false)
      @references = References.new
      self.flatten_references = flatten_references
      self.include = normalize_includes(include)
      self.prune   = normalize_includes(prune)
    end

    def for_association(association_name)
      # Shallow clone aliases @references; association traversal must not
      # "change" the context, otherwise references will be lost.
      self.dup.tap do |copy|
        copy.include = include.try { |i| i[association_name] }
        copy.prune   = prune.try   { |p| p[association_name] }
      end
    end

    def includes_member?(member_name, default)
      member_name = member_name.to_s

      # Every node in the include tree is to be included
      included = include.try { |is| is.has_key?(member_name) }
      # whereas only the leaves of the prune tree are to be removed
      pruned   = prune.try { |ps| ps.fetch(member_name, :sentinel).nil? }

      (default || included) && !pruned
    end


    def serialize_references(json)
      seen = Set.new
      while seen.size != @references.size
        @references.each do |ref, value|
          if seen.add?(ref)
            json.set!(ref) do
              ViewModel.serialize(value, json, serialize_context: self)
            end
          end
        end
      end
    end

    def serialize_references_to_hash
      Jbuilder.new { |json| serialize_references(json) }.attributes!
    end
  end
end
