class ViewModel
  class SerializationError < ViewModel::Error
    def initialize(detail)
      super(detail:   detail,
            status:   self.http_status,
            code:     self.error_type,
            metadata: self.metadata)
    end

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
