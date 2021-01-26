# frozen_string_literal: true

class ViewModel::GarbageCollection
  class << self
    def garbage_collect_references!(serialization)
      return unless serialization.has_key?('references')

      roots      = serialization.except('references')
      references = serialization['references']

      root_refs      = collect_references(roots)
      reference_refs = collect_references(references)

      loop do
        changed = false

        references.keep_if do |ref, _val|
          present = root_refs.include?(ref) || reference_refs.include?(ref)
          changed = true unless present
          present
        end

        break unless changed

        reference_refs = collect_references(references)
      end
    end

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
