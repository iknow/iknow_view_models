class ViewModel::Utils
  class << self
    def wrap_one_or_many(obj)
      return_array = obj.is_a?(Array)
      results = yield(Array.wrap(obj))
      return_array ? results : results.first
    end

    def map_one_or_many(obj)
      wrap_one_or_many(obj) do |objs|
        objs.map { |x| yield x }
      end
    end
  end
end
