# frozen_string_literal: true

class ViewModel
  class DeserializationError < ViewModel::AbstractErrorWithBlame
    status 500

    def code
      "DeserializationError.#{self.class.name.demodulize}"
    end

    protected

    def viewmodel_class
      first = nodes.first.viewmodel_class
      unless nodes.all? { |n| n.viewmodel_class == first }
        raise ArgumentError.new("All nodes must be of the same type for #{self.class.name}")
      end

      first
    end

    # A collection of DeserializationErrors
    class Collection < ViewModel::AbstractErrorCollection
      title 'Error(s) occurred during deserialization'
      code  'DeserializationError.Collection'

      def detail
        "Error(s) occurred during deserialization: #{cause_details}"
      end
    end

    # The client has provided a syntactically or structurally incoherent
    # request.
    class InvalidRequest < DeserializationError
      # Abstract
      status 400
      title 'Invalid request'
    end

    # There has been an unexpected internal failure of the ViewModel library.
    class Internal < DeserializationError
      status 500
      attr_reader :detail

      def initialize(detail, nodes = [])
        @detail = detail
        super(nodes)
      end
    end

    class InvalidStructure < InvalidRequest
      attr_reader :detail

      def initialize(detail, nodes = [])
        @detail = detail
        super(nodes)
      end
    end

    class InvalidSyntax < InvalidRequest
      attr_reader :detail

      def initialize(detail, nodes = [])
        @detail = detail
        super(nodes)
      end
    end

    # A view included a invalid shared reference
    class InvalidSharedReference < InvalidRequest
      attr_reader :reference

      def initialize(reference, node)
        @reference = reference
        super([node])
      end

      def detail
        "Could not find shared reference with key '#{reference}'"
      end

      def meta
        super.merge(reference: reference)
      end
    end

    # A view was of an unknown type
    class UnknownView < InvalidRequest
      attr_reader :type

      def initialize(type)
        @type = type
        super([])
      end

      def detail
        "ViewModel class for view name '#{type}' could not be found"
      end

      def meta
        super.merge(type: type)
      end
    end

    # A view included an unknown attribute
    class UnknownAttribute < InvalidRequest
      attr_reader :attribute

      def initialize(attribute, node)
        @attribute = attribute
        super([node])
      end

      def detail
        "Unknown attribute/association #{attribute} in viewmodel '#{viewmodel_class.view_name}'"
      end

      def meta
        super.merge(attribute: attribute)
      end
    end

    # A view included an unexpected schema version for the corresponding
    # viewmodel.
    class SchemaVersionMismatch < InvalidRequest
      attr_reader :viewmodel_class, :schema_version

      def initialize(viewmodel_class, schema_version, nodes)
        @viewmodel_class = viewmodel_class
        @schema_version  = schema_version
        super(nodes)
      end

      def detail
        "Mismatched schema version for type #{viewmodel_class.view_name}, "\
        "expected #{viewmodel_class.schema_version}, received #{schema_version}."
      end

      def meta
        super.merge(expected: viewmodel_class.schema_version,
                    received: schema_version)
      end
    end

    # The target of an association was not a valid view type for that
    # association.
    class InvalidAssociationType < InvalidRequest
      attr_reader :association, :target_type

      def initialize(association, target_type, node)
        @association = association
        @target_type = target_type
        super([node])
      end

      def detail
        "Invalid target viewmodel type '#{target_type}' for association '#{association}'"
      end

      def meta
        super.merge(association: association,
                    target_type: target_type)
      end
    end

    class InvalidViewType < InvalidRequest
      attr_reader :expected_type

      def initialize(expected_type, node)
        @expected_type = expected_type
        super(node)
      end

      def detail
        "Cannot deserialize inappropriate view type, expected '#{expected_type}' or an alias"
      end

      def meta
        super.merge(expected_type: expected_type)
      end
    end

    # Attempted to load persisted viewmodels by id, but they were not available
    class NotFound < DeserializationError
      status 404

      def detail
        model_ids = nodes.map(&:model_id)
        "Couldn't find #{viewmodel_class.view_name}(s) with id(s)=#{model_ids.inspect}"
      end
    end

    class AssociatedNotFound < NotFound
      attr_reader :missing_nodes, :association

      def initialize(association, missing_nodes, blame_nodes)
        @association   = association
        @missing_nodes = Array.wrap(missing_nodes)
        super(blame_nodes)
      end

      def detail
        errors = missing_nodes.map(&:to_s).join(', ')
        "Couldn't find requested member node(s) in association '#{association}': "\
        "#{errors}"
      end

      def meta
        super.merge(association: association,
                    missing_nodes: format_references(missing_nodes))
      end
    end

    class DuplicateNodes < InvalidRequest
      attr_reader :type

      def initialize(type, nodes)
        @type = type
        super(nodes)
      end

      def detail
        "Duplicate views for the same '#{type}' specified: " + nodes.map(&:to_s).join(', ')
      end

      def meta
        super.merge(type: type)
      end
    end

    class DuplicateOwner < InvalidRequest
      attr_reader :association_name

      def initialize(association_name, parents)
        @association_name = association_name
        super(parents)
      end

      def detail
        "Multiple parents attempted to claim the same owned '#{association_name}' reference: " + nodes.map(&:to_s).join(', ')
      end
    end

    class ParentNotFound < NotFound
      def detail
        'Could not resolve release from previous parent for the following owned viewmodel(s): ' +
          nodes.map(&:to_s).join(', ')
      end
    end

    class ReadOnlyAttribute < DeserializationError
      status 400
      attr_reader :attribute

      def initialize(attribute, node)
        @attribute = attribute
        super([node])
      end

      def detail
        "Cannot edit read only attribute '#{attribute}'"
      end

      def meta
        super.merge(attribute: attribute)
      end
    end

    class ReadOnlyAssociation < DeserializationError
      status 400
      attr_reader :association

      def initialize(association, node)
        @association = association
        super([node])
      end

      def detail
        "Cannot edit read only association '#{association}'"
      end

      def meta
        super.merge(association: association)
      end
    end

    class ReadOnlyType < DeserializationError
      status 400
      detail 'Deserialization not defined for view type'
    end

    class InvalidAttributeType < InvalidRequest
      attr_reader :attribute, :expected_type, :provided_type

      def initialize(attribute, expected_type, provided_type, node)
        @attribute     = attribute
        @expected_type = expected_type
        @provided_type = provided_type
        super([node])
      end

      def detail
        "Expected '#{attribute}' to be of type '#{expected_type}', was '#{provided_type}'"
      end

      def meta
        super.merge(attribute:     attribute,
                    expected_type: expected_type,
                    provided_type: provided_type)
      end
    end

    class InvalidParentEdit < DeserializationError
      def initialize(changes, node)
        @changes = changes
        super([node])
      end

      detail 'Illegal edit to parent during external association update'

      def meta
        super.merge(changes: @changes.to_h)
      end
    end

    # Optimistic lock failure updating nodes
    class LockFailure < DeserializationError
      status 400

      def detail
        errors = nodes.map(&:to_s).join(', ')
        "Optimistic lock failure updating nodes: #{errors}"
      end
    end

    class DatabaseConstraint < DeserializationError
      status 400
      attr_reader :detail

      def initialize(detail, nodes = [])
        @detail = detail
        super(nodes)
      end

      # Database constraint errors are pretty opaque and stringly typed. We can
      # do our best to parse out what metadata we can from the error, and fall
      # back when we can't.
      def self.from_exception(exception, nodes = [])
        case exception.cause
        when PG::UniqueViolation
          UniqueViolation.from_postgres_error(exception.cause, nodes)
        else
          self.new(exception.message, nodes)
        end
      end
    end

    class UniqueViolation < DeserializationError
      status 400
      attr_reader :detail, :constraint, :columns, :values

      PG_ERROR_FIELD_CONSTRAINT_NAME = 'n'.ord # Not exposed in pg gem
      def self.from_postgres_error(err, nodes)
        result         = err.result
        constraint     = result.error_field(PG_ERROR_FIELD_CONSTRAINT_NAME)
        message_detail = result.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL)

        columns, values = parse_message_detail(message_detail)

        unless columns
          # Couldn't parse the detail message, fall back on an unparsed error
          return DatabaseConstraint.new(err.message, nodes)
        end

        self.new(err.message, constraint, columns, values, nodes)
      end

      class << self
        DETAIL_PREFIX = 'Key ('
        DETAIL_SUFFIX = ') already exists.'
        DETAIL_INFIX  = ')=('
        def parse_message_detail(detail)
          stream = detail.dup

          return nil unless stream.delete_prefix!(DETAIL_PREFIX)
          return nil unless stream.delete_suffix!(DETAIL_SUFFIX)

          # The message should start with an identifier list: pop off identifier
          # tokens while we can.
          identifiers = []

          identifier = parse_identifier(stream)
          return nil unless identifier

          identifiers << identifier

          while stream.delete_prefix!(', ')
            identifier = parse_identifier(stream)
            return nil unless identifier

            identifiers << identifier
          end

          # The message should now contain ")=(" followed by the (unparseable)
          # value list.
          return nil unless stream.delete_prefix!(DETAIL_INFIX)

          [identifiers, stream]
        end

        private

        QUOTED_IDENTIFIER   = /\A"(?:[^"]|"")+"/
        UNQUOTED_IDENTIFIER = /\A(?:\p{Alpha}|_)(?:\p{Alnum}|_)*/
        def parse_identifier(stream)
          if (identifier = stream.slice!(UNQUOTED_IDENTIFIER))
            identifier
          elsif (quoted_identifier = stream.slice!(QUOTED_IDENTIFIER))
            quoted_identifier[1..-2].gsub('""', '"')
          else
            nil
          end
        end
      end

      def initialize(detail, constraint, columns, values, nodes = [])
        @detail     = detail
        @constraint = constraint
        @columns    = columns
        @values     = values
        super(nodes)
      end

      def meta
        super.merge(constraint: @constraint, columns: @columns, values: @values)
      end
    end

    class Validation < DeserializationError
      status 400
      attr_reader :attribute, :reason, :details

      def initialize(attribute, reason, details, node)
        @attribute = attribute
        @reason    = reason
        @details   = details
        super([node])
      end

      def detail
        "Validation failed: '#{attribute}' #{reason}"
      end

      def meta
        super.merge(attribute: attribute, message: reason, details: details)
      end

      # Return Validation errors for each error in the the provided
      # ActiveModel::Errors, wrapped in a Collection if necessary.
      def self.from_active_model(errors, node)
        causes = errors.messages.each_key.flat_map do |attr|
          errors.messages[attr].zip(errors.details[attr]).map do |message, details|
            self.new(attr.to_s, message, details, node)
          end
        end
        Collection.for_errors(causes)
      end
    end
  end
end
