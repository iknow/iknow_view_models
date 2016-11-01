class ViewModel
  class DeserializationError < StandardError
    attr_reader :nodes
    def initialize(msg, nodes = [])
      super(msg)
      @nodes = Array.wrap(nodes)
    end

    def http_status
      400
    end

    def metadata
      {
        nodes: nodes.map do |ref|
          {
            ViewModel::TYPE_ATTRIBUTE => ref.viewmodel_class.view_name,
            ViewModel::ID_ATTRIBUTE   => ref.model_id
          }
        end
      }
    end

    def error_type
      "Deserialization.#{self.class.name.demodulize}"
    end

    class Permissions < DeserializationError
      def http_status
        403
      end
    end

    class SchemaMismatch < DeserializationError
    end

    class NotFound < DeserializationError
      def http_status
        404
      end

      def self.wrap_lookup(*target_refs)
        yield
      rescue ::ActiveRecord::RecordNotFound => ex
        raise self.new(ex.message, target_refs)
      end
    end

    class LockFailure < DeserializationError
    end

    class Validation < DeserializationError
      attr_reader :validation_errors

      def initialize(msg, nodes, validation_errors = nil)
        super(msg, nodes)
        @validation_errors = validation_errors
      end

      def metadata
        super.merge(validation_errors: validation_errors)
      end
    end
  end
end
