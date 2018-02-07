class ViewModel::Utils
  module Collections
    def self.count_by(enumerable)
      enumerable.each_with_object(Hash.new(0)) do |el, counts|
        key         = yield(el)
        counts[key] += 1 unless key.nil?
      end
    end

    refine Array do
      def contains_exactly?(other)
        vals = to_set
        other.each { |o| return false unless vals.delete?(o) }
        vals.blank?
      end

      def count_by(&by)
        Collections::count_by(self, &by)
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
        Collections::count_by(self, &by)
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
