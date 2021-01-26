# frozen_string_literal: true

class ViewModel::GarbageCollection
  class << self
    def garbage_collect_references!(serialization)
      return unless serialization.has_key?('references')

      roots      = serialization.except('references')
      references = serialization['references']

      queue = []
      seen = Set.new

      collect_references(roots, queue)

      while (live = queue.shift)
        next if seen.include?(live)
        seen << live
        collect_references(references[live], queue)
      end

      references.keep_if { |ref, _val| seen.include?(ref) }
    end

    private

    def collect_references(tree, acc = Set.new)
      case tree
      when Hash
        if tree.size == 1 && (ref = tree[ViewModel::REFERENCE_ATTRIBUTE])
          acc << ref
        else
          tree.each_value { |t| collect_references(t, acc) }
        end
      when Array
        tree.each { |t| collect_references(t, acc) }
      end

      acc
    end
  end
end
