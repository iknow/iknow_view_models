class ViewModel
  class SerializationError < StandardError
    def http_status
      400
    end

    def metadata
      {}
    end

    def error_type
      "Serialization.#{self.class.name.demodulize}"
    end

    class Permissions < SerializationError
      def http_status
        403
      end
    end
  end
end
