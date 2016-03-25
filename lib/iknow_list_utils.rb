module IknowListUtils
  refine Array do
    def bsearch_max(min = nil, max = nil)
      if (idx = self.bsearch_max_index(min, max) { |x| yield(x) })
        self[idx]
      end
    end

    def bsearch_max_index(min = nil, max = nil)
      # lo and hi are valid array indexes
      lo = min || 0
      hi = max || self.count - 1

      # Lowest value has to pass predicate
      return nil unless yield(self[lo])

      # body invariant established: lo is always satisfied

      while lo < hi
        # when hi = lo + 1, mid = hi; which
        #  - either passes and sets lo' = lo + 1 (= hi) (singleton)
        #  - fails and sets hi' = lo (singleton)
        # otherwise mid is between both, and the range will be limited appropriately
        mid = lo + (hi - lo + 1) / 2
        if yield(self[mid])
          # midpoint satisfies predicate, reduce bounds, keep satisfying value
          lo = mid
        else
          # midpoint doesn't satisfy predicate, restrict below non-satsifying value
          hi = mid - 1
        end
      end

      lo
    end

    # TODO make this operate on Enumerables instead of directly accessible
    # collections.
    def longest_rising_sequence
      # https://en.wikipedia.org/wiki/Longest_increasing_subsequence

      preds = Array.new(self.length)
      ends = Array.new(self.length + 1)

      max_length = 0

      (0..self.length - 1).each do |i|
        # bsearch ends for a subsequence to append to, if not found
        lo = 1
        hi = max_length
        while lo <= hi
          mid = lo + (hi - lo + 1) / 2
          result =
            if block_given?
              yield(self[ends[mid]], self[i])
            else
              self[ends[mid]] <=> self[i]
            end

          if result >= 0
            hi = mid - 1
          else
            lo = mid + 1
          end
        end

        new_length = lo
        max_length = new_length if max_length < new_length
        preds[i] = ends[new_length - 1]
        ends[new_length] = i
      end

      result = []
      k = ends[max_length]
      max_length.downto(1) do |x|
        result[x - 1] = self[k]
        k = preds[k]
      end

      result
    end

    def longest_rising_sequence_by
      self.longest_rising_sequence { |x, y| yield(x) <=> yield(y) }
    end
  end
end
