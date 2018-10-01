# frozen_string_literal: true

class ViewModel::Utils
  class << self
    def wrap_one_or_many(obj)
      return_array = array_like?(obj)
      results = yield(Array.wrap(obj))
      return_array ? results : results.first
    end

    def map_one_or_many(obj)
      if array_like?(obj)
        obj.map { |x| yield(x) }
      else
        yield(obj)
      end
    end

    # Cover arrays and also Rails' array-like types.
    def array_like?(obj)
      obj.respond_to?(:to_ary)
    end
  end
end
