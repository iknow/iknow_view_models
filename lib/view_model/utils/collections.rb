# frozen_string_literal: true

class ViewModel::Utils
  module Collections
    def self.count_by(enumerable)
      enumerable.each_with_object({}) do |el, counts|
        key = yield(el)

        unless key.nil?
          counts[key] = (counts[key] || 0) + 1
        end
      end
    end

    refine Array do
      def contains_exactly?(other)
        mine   = count_by { |x| x }
        theirs = other.count_by { |x| x }
        mine == theirs
      end

      def count_by(&by)
        Collections.count_by(self, &by)
      end

      def duplicates_by(&by)
        count_by(&by).delete_if { |_, count| count == 1 }
      end

      def duplicates
        duplicates_by { |x| x }
      end
    end

    refine Hash do
      def count_by(&by)
        Collections.count_by(self, &by)
      end

      def duplicates_by(&by)
        count_by(&by).delete_if { |_, count| count == 1 }
      end

      def duplicates
        duplicates_by { |x| x }
      end
    end
  end
end
