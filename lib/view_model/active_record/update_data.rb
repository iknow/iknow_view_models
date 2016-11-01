require 'renum'
require 'json'
require 'json_schema'

class ViewModel::ActiveRecord
  using Collections


  class FunctionalUpdate
    attr_reader :values

    def initialize(values)
      @values = values
    end

    def self.for_type(type)
      case type
      when Append::NAME
        return Append
      when Remove::NAME
        return Remove
      when Update::NAME
        return Update
      else
        raise ArgumentError.new("invalid functional update type #{type}")
      end
    end

    class Append < self
      NAME = 'append'
      attr_accessor :before, :after
      def self.schema
        UpdateData::Schemas::APPEND_ACTION
      end
    end

    class Remove < self
      NAME = 'remove'
      def self.schema
        UpdateData::Schemas::REMOVE_ACTION
      end
    end

    class Update < self
      NAME = 'update'
      def self.schema
        UpdateData::Schemas::UPDATE_ACTION
      end
    end
  end

  class CollectionUpdate
    attr_reader :values

    def initialize(values)
      @values = values
    end

    class Replace < self
      def update_datas
        values
      end
    end

    class Functional < self
      def update_datas
        values.flat_map(&:values)
      end
    end
  end

  class UpdateData
    attr_accessor :viewmodel_class, :id, :new, :attributes, :associations, :referenced_associations

    module Schemas
      id = { 'oneOf' => [{ 'type' => 'integer' },
                         { 'type' => 'string', 'format' => 'uuid' }] }

      type = { 'type' => 'string' }

      reference =
        {
          'type'                 => 'object',
          'description'          => 'shared reference',
          'properties'           => { ViewModel::REFERENCE_ATTRIBUTE => type },
          'additionalProperties' => false,
          'required'             => [ViewModel::REFERENCE_ATTRIBUTE],
        }
      REFERENCE = JsonSchema.parse!(reference)

      JsonSchema.configure do |c|
        uuid_format = /\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\Z/
        c.register_format('uuid', ->(value) { uuid_format.match(value) })
      end

      viewmodel_update =
        {
          'type'        => 'object',
          'description' => 'viewmodel update',
          'properties'  => { ViewModel::TYPE_ATTRIBUTE    => type,
                             ViewModel::ID_ATTRIBUTE      => id,
                             NEW_ATTRIBUTE                => { 'type' => 'boolean' },
                             ViewModel::VERSION_ATTRIBUTE => { 'type' => 'integer' } },
          'required'    => [ViewModel::TYPE_ATTRIBUTE]
        }
      VIEWMODEL_UPDATE = JsonSchema.parse!(viewmodel_update)


      viewmodel_reference =
        {
          'type'                 => 'object',
          'description'          => 'viewmodel reference',
          'properties'           => { ViewModel::TYPE_ATTRIBUTE => type,
                                      ViewModel::ID_ATTRIBUTE   => id },
          'additionalProperties' => false,
          'required'             => [ViewModel::TYPE_ATTRIBUTE, ViewModel::ID_ATTRIBUTE]
        }

      base_functional_update_schema =
        {
          'description' => 'functional update',
          'type'        => 'object',
          'properties'  => {
            ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FunctionalUpdate::Append::NAME,
                                                      FunctionalUpdate::Update::NAME,
                                                      FunctionalUpdate::Remove::NAME] },
            VALUES_ATTRIBUTE => { 'type'  => 'array',
                                  'items' => viewmodel_update }
          },
          'required' => [ViewModel::TYPE_ATTRIBUTE, VALUES_ATTRIBUTE]
        }

      append = base_functional_update_schema.deep_merge(
        {
          'description'          => 'collection append',
          'additionalProperties' => false,
          'properties'           => {
            ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FunctionalUpdate::Append::NAME] },
            BEFORE_ATTRIBUTE => viewmodel_reference,
            AFTER_ATTRIBUTE  => viewmodel_reference
          },
        }
      )

      APPEND_ACTION = JsonSchema.parse!(append)

      update = base_functional_update_schema.deep_merge(
        {
          'description'          => 'collection update',
          'additionalProperties' => false,
          'properties'           => {
            ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FunctionalUpdate::Update::NAME] }
          },
        }
      )

      UPDATE_ACTION = JsonSchema.parse!(update)

      remove = base_functional_update_schema.deep_merge(
        {
          'description'          => 'collection remove',
          'additionalProperties' => false,
          'properties'           => {
            ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FunctionalUpdate::Remove::NAME] },
            # The VALUES_ATTRIBUTE should be a viewmodel_reference, but in the
            # name of error messages, we allow more keys and check the
            # constraint in code.
          },
        }
      )

      REMOVE_ACTION = JsonSchema.parse!(remove)

      collection_update =
        {
          'type'        => 'object',
          'description' => 'collection functional update',
          'properties'  => {
            ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FUNCTIONAL_UPDATE_TYPE] },
            ACTIONS_ATTRIBUTE => { 'type' => 'array', 'items' => base_functional_update_schema }
            # The ACTIONS_ATTRIBUTE could be accurately expressed as
            #
            #   { 'oneOf' => [append, update, remove] }
            #
            # but this produces completely unusable error messages.  Instead we
            # specify it must be an array, and defer checking to the code that
            # can determine the schema by inspecting the type field.
          }
        }
      COLLECTION_UPDATE = JsonSchema.parse!(collection_update)
    end

    def [](name)
      case name
      when :id
        id
      when :_type
        viewmodel_class.view_name
      else
        attributes.fetch(name) { associations.fetch(name) { referenced_associations.fetch(name) }}
      end
    end

    def has_key?(name)
      case name
      when :id, :_type
        true
      else
        attributes.has_key?(name) || associations.has_key?(name) || referenced_associations.has_key?(name)
      end
    end

    alias new? new

    def self.verify_schema!(schema, value)
      valid, errors = schema.validate(value)
      unless valid
        error_list = errors.map { |e| "#{e.pointer}: #{e.message}" }.join("\n")
        errors     = 'Error'.pluralize(errors.length)
        raise ViewModel::DeserializationError.new("#{errors} parsing #{schema.description}:\n#{error_list}")
      end
    end

    def self.parse_hashes(root_subtree_hashes, referenced_subtree_hashes = {})
      valid_reference_keys = referenced_subtree_hashes.keys.to_set

      valid_reference_keys.each do |ref|
        raise ViewModel::DeserializationError.new("Invalid reference string: #{ref}") unless ref.is_a?(String)
      end

      # Construct root UpdateData
      root_updates = root_subtree_hashes.map do |subtree_hash|
        viewmodel_name, schema_version, id, new = extract_viewmodel_metadata(subtree_hash)
        viewmodel_class                         = ViewModel::ActiveRecord.for_view_name(viewmodel_name)
        verify_schema_version!(viewmodel_class, schema_version, id) if schema_version
        UpdateData.new(viewmodel_class, id, new, subtree_hash, valid_reference_keys)
      end

      # Ensure that no root is referred to more than once
      check_duplicates(root_updates, type: "root") { |upd| [upd.viewmodel_class, upd.id] if upd.id }

      # Construct reference UpdateData
      referenced_updates = referenced_subtree_hashes.transform_values do |subtree_hash|
        viewmodel_name, schema_version, id, new = extract_viewmodel_metadata(subtree_hash)
        viewmodel_class                         = ViewModel::ActiveRecord.for_view_name(viewmodel_name)
        verify_schema_version!(viewmodel_class, schema_version, id) if schema_version

        UpdateData.new(viewmodel_class, id, new, subtree_hash, valid_reference_keys)
      end

      check_duplicates(referenced_updates, type: "reference") { |ref, upd| [upd.viewmodel_class, upd.id] if upd.id }

      return root_updates, referenced_updates
    end

    def self.extract_viewmodel_metadata(hash)
      verify_schema!(Schemas::VIEWMODEL_UPDATE, hash)
      id             = hash.delete(ViewModel::ID_ATTRIBUTE)
      type_name      = hash.delete(ViewModel::TYPE_ATTRIBUTE)
      schema_version = hash.delete(ViewModel::VERSION_ATTRIBUTE)
      new            = hash.delete(NEW_ATTRIBUTE) { false }
      return type_name, schema_version, id, new
    end

    def self.extract_reference_metadata(hash)
      verify_schema!(Schemas::REFERENCE, hash)
      hash.delete(ViewModel::REFERENCE_ATTRIBUTE)
    end

    def self.check_duplicates(arr, type:, &by)
      # Ensure that no root is referred to more than once
      duplicates = arr.duplicates(&by)
      if duplicates.present?
        raise ViewModel::DeserializationError.new("Duplicate #{type}(s) specified: '#{duplicates.keys.to_h}'")
      end
    end

    def initialize(viewmodel_class, id, new, hash_data, valid_reference_keys)
      self.viewmodel_class = viewmodel_class
      self.id = id
      self.new = id.nil? || new
      self.attributes = {}
      self.associations = {}
      self.referenced_associations = {}

      parse(hash_data, valid_reference_keys)
    end

    def self.empty_update_for(viewmodel)
      self.new(viewmodel.class, viewmodel.id, false, {}, [])
    end

    # Normalised handler for looking at the UpdateData for an association
    def reduce_association(name, value, empty:, map:, inject:)
      association_data = self.viewmodel_class._association_data(name)
      case
      when value.nil?
        empty.()
      when association_data.collection?
        if association_data.shared?
          value.map(&map).inject(empty.(), &inject)
        else
          value.update_datas.map(&map).inject(empty.(), &inject)
        end
      else
        inject.(empty.(), map.(value))
      end
    end

    # Normalised handler for looking at UpdateData for an association where the
    # result is a deeply merged hash
    def reduce_association_to_hash(name, value, &map)
      reduce_association(
        name, value,
        empty:  ->() { {} },
        inject: ->(acc, data) { acc.deep_merge(data) },
        map:    map)
    end

    # Updates in terms of viewmodel associations
    def updated_associations(referenced_updates)
      deps = {}

      associations.each do |assoc_name, assoc_update|
        deps[assoc_name] = reduce_association_to_hash(assoc_name, assoc_update) do |update_data|
          update_data.updated_associations(referenced_updates)
        end
      end

      referenced_associations.each do |assoc_name, reference|
        deps[assoc_name] = reduce_association_to_hash(assoc_name, reference) do |ref|
          referenced_updates[ref].updated_associations(referenced_updates)
        end
      end

      deps
    end

    def reduce_association_to_preload(name, value, polymorphic, &update_data_map)
      if polymorphic
        empty = ->{ DeepPreloader::PolymorphicSpec.new }
        map   = ->(update_data) {
          target_model = update_data.viewmodel_class.model_class
          DeepPreloader::PolymorphicSpec.new(target_model.name => update_data_map.(update_data))
        }
      else
        empty = ->{ DeepPreloader::Spec.new }
        map   = update_data_map
      end

      reduce_association(name, value,
                         empty:  empty,
                         inject: ->(a, b){ a.merge!(b) },
                         map:    map)
    end

    # Updates in terms of activerecord associations: used for preloading subtree
    # associations necessary to perform update.
    def preload_dependencies(referenced_updates)
      deps = {}

      associations.each do |assoc_name, assoc_update|
        association_data = self.viewmodel_class._association_data(assoc_name)

        assoc_deps = reduce_association_to_preload(assoc_name, assoc_update, association_data.polymorphic?) do |update_data|
          update_data.preload_dependencies(referenced_updates)
        end

        deps[association_data.direct_reflection.name.to_s] = assoc_deps
      end

      referenced_associations.each do |assoc_name, reference|
        association_data = self.viewmodel_class._association_data(assoc_name)
        resolved_updates =
          if association_data.collection?
            reference.map { |r| referenced_updates[r] }
          else
            referenced_updates[reference]
          end

        referenced_deps =
          reduce_association_to_preload(assoc_name, resolved_updates, association_data.polymorphic?) do |update_data|
            update_data.preload_dependencies(referenced_updates)
          end

        if association_data.through?
          referenced_deps = DeepPreloader::Spec.new(association_data.indirect_reflection.name.to_s => referenced_deps)
        end

        deps[association_data.direct_reflection.name.to_s] = referenced_deps
      end

      DeepPreloader::Spec.new(deps)
    end

    def viewmodel_reference
      ViewModel::Reference.new(viewmodel_class, id)
    end

    private

    def reference_only_hash?(hash)
      hash.size == 2 && hash.has_key?(ViewModel::ID_ATTRIBUTE) && hash.has_key?(ViewModel::TYPE_ATTRIBUTE)
    end

    def parse(hash_data, valid_reference_keys)
      hash_data = hash_data.dup

      # handle view pre-parsing if defined
      self.viewmodel_class.pre_parse(viewmodel_reference, hash_data) if self.viewmodel_class.respond_to?(:pre_parse)
      hash_data.keys.each do |key|
        if self.viewmodel_class.respond_to?(:"pre_parse_#{key}")
          self.viewmodel_class.public_send("pre_parse_#{key}", viewmodel_reference, hash_data, hash_data.delete(key))
        end
      end

      hash_data.each do |name, value|
        member_data = self.viewmodel_class._members[name]
        case member_data
        when AttributeData
          attributes[name] = value

        when AssociationData
          association_data = member_data
          case
          when value.nil?
            if association_data.collection?
              raise_deserialization_error("Invalid collection update value 'nil' for association '#{name}'")
            end
            associations[name] = nil

          when association_data.through?
            referenced_associations[name] = value.map do |ref_value|
              ref = UpdateData.extract_reference_metadata(ref_value)
              unless valid_reference_keys.include?(ref)
                raise_deserialization_error("Could not parse unresolvable reference '#{ref}' for association '#{name}'")
              end
              ref
            end

          when association_data.shared?
            # Extract and check reference
            ref = UpdateData.extract_reference_metadata(value)

            unless valid_reference_keys.include?(ref)
              raise_deserialization_error("Could not parse unresolvable reference '#{ref}' for association '#{name}'")
            end

            referenced_associations[name] = ref

          else
            # Recurse into child
            parse_association = ->(child_hash) do
              child_viewmodel_name, child_schema_version, child_id, child_new =
                UpdateData.extract_viewmodel_metadata(child_hash)

              child_viewmodel_class =
                association_data.viewmodel_class_for_name(child_viewmodel_name)

              if child_viewmodel_class.nil?
                raise_deserialization_error("Invalid target viewmodel type '#{child_viewmodel_name}' for association '#{association_data.target_reflection.name}'")
              end

              self.class.verify_schema_version!(child_viewmodel_class, child_schema_version, child_id) if child_schema_version

              UpdateData.new(child_viewmodel_class, child_id, child_new, child_hash, valid_reference_keys)
            end

            if association_data.collection?
              associations[name] =
                case value
                when Array
                  children = value.map { |child_hash| parse_association.(child_hash) }
                  CollectionUpdate::Replace.new(children)

                when Hash
                  UpdateData.verify_schema!(Schemas::COLLECTION_UPDATE, value)
                  functional_updates = value[ACTIONS_ATTRIBUTE].map do |action|
                    type   = FunctionalUpdate.for_type(action[ViewModel::TYPE_ATTRIBUTE])
                    values = action[VALUES_ATTRIBUTE]

                    UpdateData.verify_schema!(type.schema, action)

                    # There's no reasonable interpretation of a remove update that includes data.
                    # Report it as soon as we detect it.
                    if type == FunctionalUpdate::Remove
                      invalid_entries = values.reject { |h| reference_only_hash?(h) }
                      if invalid_entries.present?
                        raise_deserialization_error(
                          "Removed entities must have only #{ViewModel::TYPE_ATTRIBUTE} and #{ViewModel::ID_ATTRIBUTE} fields. " \
                          "Invalid entries: #{invalid_entries}")
                      end
                    end

                    values = action[VALUES_ATTRIBUTE].map(&parse_association)

                    update = type.new(values)

                    # Each type may have additional metadata for that type.

                    if type == FunctionalUpdate::Append
                      if (before = action[BEFORE_ATTRIBUTE])
                        update.before = parse_association.(before)
                      end

                      if (after = action[AFTER_ATTRIBUTE])
                        update.after = parse_association.(after)
                      end

                      if before && after
                        raise ViewModel::DeserializationError.new("Append may not specify both 'after' and 'before'")
                      end
                    end

                    update
                  end
                  CollectionUpdate::Functional.new(functional_updates)

                else
                  raise_deserialization_error("Could not parse non-array value for collection association '#{name}'")
                end

            else # not a collection
              associations[name] =
                if value.nil?
                  nil
                else
                  parse_association.(value)
                end
            end
          end
        else
          raise_deserialization_error("Could not parse unknown attribute/association #{name.inspect} in viewmodel '#{viewmodel_class.view_name}'")
        end
      end
    end

    def raise_deserialization_error(msg, *args, error: ViewModel::DeserializationError)
      raise error.new(msg, [ViewModel::Reference.new(self.viewmodel_class, self.id)], *args)
    end

    def self.verify_schema_version!(viewmodel_class, schema_version, id)
      unless viewmodel_class.accepts_schema_version?(schema_version)
        raise ViewModel::DeserializationError::SchemaMismatch.new(
                "Mismatched schema version for type #{viewmodel_class.view_name}, "\
                "expected #{viewmodel_class.schema_version}, received #{schema_version}.",
                ViewModel::Reference.new(viewmodel_class, id))
      end
    end
  end
end
