# frozen_string_literal: true

class ViewModel::GarbageCollection
  class << self
    def garbage_collect_references!(serialization)
      return unless serialization.has_key?('references')

      roots      = serialization.except('references')
      references = serialization['references']

      worklist = Set.new(collect_references(roots))
      visited  = Set.new

      while (live = worklist.first)
        worklist.delete(live)
        visited << live
        collect_references(references[live]) do |ref|
          worklist << ref unless visited.include?(ref)
        end
      end

      references.keep_if { |ref, _val| visited.include?(ref) }
    end

    private

    ## yield each reference encountered in tree
    def collect_references(tree, &block)
      return enum_for(__method__, tree) unless block_given?

      case tree
      when Hash
        if tree.size == 1 && (ref = tree[ViewModel::REFERENCE_ATTRIBUTE])
          block.(ref)
        else
          tree.each_value { |t| collect_references(t, &block) }
        end
      when Array
        tree.each { |t| collect_references(t, &block) }
      end
    end
  end
end
