class ViewModel
  class SerializationError < ViewModel::AbstractError
    def status
      400
    end

    def code
      "Serialization.#{self.class.name.demodulize}"
    end

    class Permissions < SerializationError
      def status
        403
      end
    end
  end
end
