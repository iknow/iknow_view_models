# frozen_string_literal: true

require 'renum'
require 'view_model/schemas'

class ViewModel::ActiveRecord
  using ViewModel::Utils::Collections

  class FunctionalUpdate
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

    class Append
      NAME = 'append'
      attr_accessor :before, :after
      attr_reader :contents

      def initialize(contents)
        @contents = contents
      end
    end

    class Update
      NAME = 'update'
      attr_reader :contents

      def initialize(contents)
        @contents = contents
      end
    end

    class Remove
      NAME = 'remove'
      attr_reader :removed_vm_refs

      def initialize(removed_vm_refs)
        @removed_vm_refs = removed_vm_refs
      end
    end
  end

  # Parser for collection updates. Collection updates have a regular structure,
  # but vary based on the contents. Parsing a nested collection recurses deeply
  # and creates a tree of UpdateDatas, while parsing a referenced collection
  # collects reference strings.
  class AbstractCollectionUpdate
    # Wraps a complete collection of new data: either UpdateDatas for non-root
    # associations or reference strings for root.
    class Replace
      attr_reader :contents

      def initialize(contents)
        @contents = contents
      end
    end

    # Wraps an ordered list of FunctionalUpdates, each of whose `contents` are
    # either UpdateData for nested associations or references for referenced
    # associations.
    class Functional
      attr_reader :actions

      def initialize(actions)
        @actions = actions
      end

      def contents
        actions.lazy
          .reject { |action| action.is_a?(FunctionalUpdate::Remove) }
          .flat_map(&:contents)
          .to_a
      end

      def vm_references(update_context)
        used_vm_refs(update_context) + removed_vm_refs
      end

      # Resolve ViewModel::References used in the update's contents, whether by
      # reference or value.
      def used_vm_refs(_update_context)
        raise RuntimeError.new('abstract method')
      end

      def removed_vm_refs
        actions.lazy
          .select { |action| action.is_a?(FunctionalUpdate::Remove) }
          .flat_map(&:removed_vm_refs)
          .to_a
      end

      def check_for_duplicates!(update_context, blame)
        duplicate_vm_refs = vm_references(update_context).duplicates
        if duplicate_vm_refs.present?
          formatted_invalid_ids = duplicate_vm_refs.keys.map(&:to_s).join(', ')
          raise ViewModel::DeserializationError::InvalidStructure.new("Duplicate functional update targets: [#{formatted_invalid_ids}]", blame)
        end
      end
    end

    class Parser
      def initialize(association_data, blame_reference, valid_reference_keys)
        @association_data     = association_data
        @blame_reference      = blame_reference
        @valid_reference_keys = valid_reference_keys
      end

      def parse(value)
        case value
        when Array
          replace_update_type.new(parse_contents(value))

        when Hash
          ViewModel::Schemas.verify_schema!(functional_update_schema, value)
          functional_updates = value[ACTIONS_ATTRIBUTE].map { |action| parse_action(action) }
          functional_update_type.new(functional_updates)

        else
          raise ViewModel::DeserializationError::InvalidSyntax.new(
                  "Could not parse non-array value for collection association '#{association_data}'",
                  blame_reference)
        end
      end

      protected

      attr_reader :association_data, :blame_reference, :valid_reference_keys

      private

      def parse_action(action)
        type = action[ViewModel::TYPE_ATTRIBUTE]

        case type
        when FunctionalUpdate::Remove::NAME
          parse_remove_action(action)
        when FunctionalUpdate::Append::NAME
          parse_append_action(action)
        when FunctionalUpdate::Update::NAME
          parse_update_action(action)
        else
          raise ViewModel::DeserializationError::InvalidSyntax.new(
                  "Unknown action type '#{type}'",
                  blame_reference)
        end
      end

      ## Action parsers
      #
      # The shape of the actions are always the same

      # Parse an anchor for a functional_update, before/after
      # May only contain type and id fields, is never a reference even for
      # referenced associations.
      def parse_anchor(child_hash) # final
        child_metadata = ViewModel.extract_reference_only_metadata(child_hash)

        child_viewmodel_class =
          association_data.viewmodel_class_for_name(child_metadata.view_name)

        if child_viewmodel_class.nil?
          raise ViewModel::DeserializationError::InvalidAssociationType.new(
                  association_data.association_name.to_s,
                  child_metadata.view_name,
                  blame_reference)
        end

        ViewModel::Reference.new(child_viewmodel_class, child_metadata.id)
      end

      def parse_append_action(action) # final
        ViewModel::Schemas.verify_schema!(append_action_schema, action)

        values = action[VALUES_ATTRIBUTE]
        update = FunctionalUpdate::Append.new(parse_contents(values))

        if (before = action[BEFORE_ATTRIBUTE])
          update.before = parse_anchor(before)
        end

        if (after = action[AFTER_ATTRIBUTE])
          update.after = parse_anchor(after)
        end

        if before && after
          raise ViewModel::DeserializationError::InvalidSyntax.new(
                  "Append may not specify both 'after' and 'before'",
                  blame_reference)
        end

        update
      end

      def parse_update_action(action) # final
        ViewModel::Schemas.verify_schema!(update_action_schema, action)

        values = action[VALUES_ATTRIBUTE]
        FunctionalUpdate::Update.new(parse_contents(values))
      end

      def parse_remove_action(action) # final
        ViewModel::Schemas.verify_schema!(remove_action_schema, action)

        values = action[VALUES_ATTRIBUTE]
        FunctionalUpdate::Remove.new(parse_remove_values(values))
      end

      ## Action contents
      #
      # The contents of the actions are determined by the subclasses

      def functional_update_schema # abstract
        raise 'abstract'
      end

      def append_action_schema # abstract
        raise 'abstract'
      end

      def remove_action_schema # abstract
        raise 'abstract'
      end

      def update_action_schema # abstract
        raise 'abstract'
      end

      def parse_contents(_values) # abstract
        raise 'abstract'
      end

      # Remove values are always anchors
      def parse_remove_values(values)
        # There's no reasonable interpretation of a remove update that includes data.
        # Report it as soon as we detect it.
        invalid_entries = values.reject { |h| UpdateData.reference_only_hash?(h) }
        if invalid_entries.present?
          raise ViewModel::DeserializationError::InvalidSyntax.new(
                  "Removed entities must have only #{ViewModel::TYPE_ATTRIBUTE} and #{ViewModel::ID_ATTRIBUTE} fields. " \
                  "Invalid entries: #{invalid_entries}",
                  blame_reference)
        end

        values.map { |value| parse_anchor(value) }
      end

      ## Value constructors
      #
      # ReferencedCollectionUpdates and OwnedCollectionUpdates have different
      # behaviour, so we parameterise the result type as well.

      def replace_update_type # abstract
        raise 'abstract'
      end

      def functional_update_type # abstract
        raise 'abstract'
      end
    end
  end

  class OwnedCollectionUpdate < AbstractCollectionUpdate
    class Replace < AbstractCollectionUpdate::Replace
      alias update_datas contents # as UpdateDatas
    end

    class Functional < AbstractCollectionUpdate::Functional
      alias update_datas contents # as UpdateDatas

      def used_vm_refs(update_context)
        update_datas
          .map { |upd| resolve_vm_reference(upd, update_context) }
          .compact
      end

      def resolve_vm_reference(update_data, _update_context)
        update_data.viewmodel_reference if update_data.id
      end
    end

    class Parser < AbstractCollectionUpdate::Parser
      def functional_update_schema
        UpdateData::Schemas::COLLECTION_UPDATE
      end

      def append_action_schema
        UpdateData::Schemas::APPEND_ACTION
      end

      def remove_action_schema
        UpdateData::Schemas::REMOVE_ACTION
      end

      def update_action_schema
        UpdateData::Schemas::UPDATE_ACTION
      end

      def parse_contents(values)
        values.map do |value|
          UpdateData.parse_associated(association_data, blame_reference, valid_reference_keys, value)
        end
      end

      def replace_update_type
        Replace
      end

      def functional_update_type
        Functional
      end
    end
  end

  class ReferencedCollectionUpdate < AbstractCollectionUpdate
    class Replace < AbstractCollectionUpdate::Replace
      alias references contents # as reference strings
    end

    class Functional < AbstractCollectionUpdate::Functional
      alias references contents

      def used_vm_refs(update_context)
        references.map do |ref|
          resolve_vm_reference(ref, update_context)
        end
      end

      def resolve_vm_reference(ref, update_context)
        update_context.resolve_reference(ref, nil).viewmodel_reference
      end
    end

    class Parser < AbstractCollectionUpdate::Parser
      def functional_update_schema
        UpdateData::Schemas::REFERENCED_COLLECTION_UPDATE
      end

      def append_action_schema
        UpdateData::Schemas::REFERENCED_APPEND_ACTION
      end

      def remove_action_schema
        UpdateData::Schemas::REFERENCED_REMOVE_ACTION
      end

      def update_action_schema
        UpdateData::Schemas::REFERENCED_UPDATE_ACTION
      end

      def parse_contents(values)
        invalid_entries = values.reject { |h| ref_hash?(h) }

        if invalid_entries.present?
          raise ViewModel::DeserializationError::InvalidSyntax.new(
            "Appended/Updated entities must be specified as '#{ViewModel::REFERENCE_ATTRIBUTE}' style hashes." \
            "Invalid entries: #{invalid_entries}",
            blame_reference)
        end

        values.map do |x|
          ref = ViewModel.extract_reference_metadata(x)
          unless valid_reference_keys.include?(ref)
            raise ViewModel::DeserializationError::InvalidSharedReference.new(ref, blame_reference)
          end

          ref
        end
      end

      private

      def replace_update_type
        Replace
      end

      def functional_update_type
        Functional
      end

      def ref_hash?(value)
        value.size == 1 && value.has_key?(ViewModel::REFERENCE_ATTRIBUTE)
      end
    end
  end

  class UpdateData
    attr_accessor :viewmodel_class, :metadata, :attributes, :associations, :referenced_associations

    delegate :id, :view_name, :schema_version, to: :metadata

    module Schemas
      viewmodel_reference_only =
        {
          'type'                 => 'object',
          'description'          => 'viewmodel reference',
          'properties'           => { ViewModel::TYPE_ATTRIBUTE => { 'type' => 'string' },
                                      ViewModel::ID_ATTRIBUTE   => ViewModel::Schemas::ID_SCHEMA },
          'additionalProperties' => false,
          'required'             => [ViewModel::TYPE_ATTRIBUTE, ViewModel::ID_ATTRIBUTE],
        }

      VIEWMODEL_REFERENCE_ONLY = JsonSchema.parse!(viewmodel_reference_only)

      fupdate_base = ->(value_schema) do
        {
          'description' => 'functional update',
          'type'        => 'object',
          'required'    => [ViewModel::TYPE_ATTRIBUTE, VALUES_ATTRIBUTE],
          'properties'  => {
            ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FunctionalUpdate::Append::NAME,
                                                      FunctionalUpdate::Update::NAME,
                                                      FunctionalUpdate::Remove::NAME,] },
            VALUES_ATTRIBUTE => { 'type'  => 'array',
                                  'items' => value_schema },
          },
        }
      end

      append_mixin = {
        'description'          => 'collection append',
        'additionalProperties' => false,
        'properties'           => {
          ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FunctionalUpdate::Append::NAME] },
          BEFORE_ATTRIBUTE          => viewmodel_reference_only,
          AFTER_ATTRIBUTE           => viewmodel_reference_only,
        },
      }

      fupdate_owned =
        fupdate_base.(ViewModel::Schemas::VIEWMODEL_UPDATE_SCHEMA)

      fupdate_shared =
        fupdate_base.({ 'oneOf' => [ViewModel::Schemas::VIEWMODEL_REFERENCE_SCHEMA,
                                    viewmodel_reference_only,] })

      # Referenced updates are special:
      #  - Append requires `_ref` hashes
      #  - Update requires `_ref` hashes
      #  - Remove requires vm refs (type/id)
      # Checked in code (ReferencedCollectionUpdate::Builder.parse_*_values)

      APPEND_ACTION            = JsonSchema.parse!(fupdate_owned.deep_merge(append_mixin))
      REFERENCED_APPEND_ACTION = JsonSchema.parse!(fupdate_shared.deep_merge(append_mixin))

      update_mixin = {
        'description'          => 'collection update',
        'additionalProperties' => false,
        'properties'           => {
          ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FunctionalUpdate::Update::NAME] },
        },
      }

      UPDATE_ACTION            = JsonSchema.parse!(fupdate_owned.deep_merge(update_mixin))
      REFERENCED_UPDATE_ACTION = JsonSchema.parse!(fupdate_shared.deep_merge(update_mixin))

      remove_mixin = {
        'description'          => 'collection remove',
        'additionalProperties' => false,
        'properties'           => {
          ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FunctionalUpdate::Remove::NAME] },
          # The VALUES_ATTRIBUTE should be a viewmodel_reference, but in the
          # name of error messages, we allow more keys and check the
          # constraint in code.
        },
      }

      REMOVE_ACTION            = JsonSchema.parse!(fupdate_owned.deep_merge(remove_mixin))
      REFERENCED_REMOVE_ACTION = JsonSchema.parse!(fupdate_shared.deep_merge(remove_mixin))

      collection_update = ->(base_schema) do
        {
          'type'                 => 'object',
          'description'          => 'collection functional update',
          'additionalProperties' => false,
          'required'             => [ViewModel::TYPE_ATTRIBUTE, ACTIONS_ATTRIBUTE],
          'properties'           => {
            ViewModel::TYPE_ATTRIBUTE => { 'enum' => [FUNCTIONAL_UPDATE_TYPE] },
            ACTIONS_ATTRIBUTE => { 'type' => 'array', 'items' => base_schema },
            # The ACTIONS_ATTRIBUTE could be accurately expressed as
            #
            #   { 'oneOf' => [append, update, remove] }
            #
            # but this produces completely unusable error messages.  Instead we
            # specify it must be an array, and defer checking to the code that
            # can determine the schema by inspecting the type field.
          },
        }
      end

      COLLECTION_UPDATE            = JsonSchema.parse!(collection_update.(fupdate_owned))
      REFERENCED_COLLECTION_UPDATE = JsonSchema.parse!(collection_update.(fupdate_shared))
    end

    def [](name)
      case name
      when :id
        id
      when :_type
        viewmodel_class.view_name
      else
        attributes.fetch(name) { associations.fetch(name) { referenced_associations.fetch(name) } }
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

    delegate :new?, :child_update?, :auto_child_update?, to: :metadata

    def reference_only?
      attributes.empty? && associations.empty? && referenced_associations.empty?
    end

    def self.parse_hashes(root_subtree_hashes, referenced_subtree_hashes = {})
      valid_reference_keys = referenced_subtree_hashes.keys.to_set

      valid_reference_keys.each do |ref|
        unless ref.is_a?(String)
          raise ViewModel::DeserializationError::InvalidSyntax.new("Invalid reference string: #{ref}")
        end
      end

      # Construct root UpdateData
      root_updates = root_subtree_hashes.map do |subtree_hash|
        metadata = ViewModel.extract_viewmodel_metadata(subtree_hash)
        viewmodel_class = ViewModel::Registry.for_view_name(metadata.view_name)
        verify_schema_version!(viewmodel_class, metadata.schema_version, metadata.id) if metadata.schema_version
        UpdateData.new(viewmodel_class, metadata, subtree_hash, valid_reference_keys)
      end

      # Ensure that no root is referred to more than once
      check_duplicate_updates(root_updates, type: 'root')

      # Construct reference UpdateData
      referenced_updates = referenced_subtree_hashes.transform_values do |subtree_hash|
        metadata = ViewModel.extract_viewmodel_metadata(subtree_hash)
        viewmodel_class = ViewModel::Registry.for_view_name(metadata.view_name)
        verify_schema_version!(viewmodel_class, metadata.schema_version, metadata.id) if metadata.schema_version

        UpdateData.new(viewmodel_class, metadata, subtree_hash, valid_reference_keys)
      end

      check_duplicate_updates(referenced_updates.values, type: 'reference')

      return root_updates, referenced_updates
    end

    def self.check_duplicate_updates(updates, type:)
      # Ensure that no root is referred to more than once
      duplicates = updates.duplicates_by { |upd| upd.viewmodel_reference if upd.id }
      if duplicates.present?
        raise ViewModel::DeserializationError::DuplicateNodes.new(type, duplicates.keys)
      end
    end

    def initialize(viewmodel_class, metadata, hash_data, valid_reference_keys)
      self.viewmodel_class = viewmodel_class
      self.metadata        = metadata
      self.attributes      = {}
      self.associations    = {}
      self.referenced_associations = {}

      parse(hash_data, valid_reference_keys)
    end

    def self.empty_update_for(viewmodel)
      metadata = ViewModel::Metadata.new(viewmodel.id, viewmodel.view_name, viewmodel.class.schema_version, false)
      self.new(viewmodel.class, metadata, {}, [])
    end

    # Produce a sequence of update datas for a given association update value, in the spirit of Array.wrap.
    def to_sequence(name, value)
      association_data = self.viewmodel_class._association_data(name)
      case
      when value.nil?
        []
      when association_data.referenced?
        []
      when association_data.collection? # nested, because of referenced? check above
        value.update_datas
      else
        [value]
      end
    end

    def build_preload_specs(association_data, updates)
      if association_data.polymorphic?
        updates.map do |update_data|
          target_model = update_data.viewmodel_class.model_class
          DeepPreloader::PolymorphicSpec.new(
            target_model.name => update_data.preload_dependencies)
        end
      else
        updates.map { |update_data| update_data.preload_dependencies }
      end
    end

    def merge_preload_specs(association_data, specs)
      empty = association_data.polymorphic? ? DeepPreloader::PolymorphicSpec.new : DeepPreloader::Spec.new
      specs.inject(empty) { |acc, spec| acc.merge!(spec) }
    end

    # Updates in terms of activerecord associations: used for preloading subtree
    # associations necessary to perform update.
    def preload_dependencies
      deps = {}

      associations.merge(referenced_associations).each do |assoc_name, reference|
        association_data = self.viewmodel_class._association_data(assoc_name)

        preload_specs = build_preload_specs(association_data,
                                            to_sequence(assoc_name, reference))

        referenced_deps = merge_preload_specs(association_data, preload_specs)

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

    def self.parse_associated(association_data, blame_reference, valid_reference_keys, child_hash)
      child_metadata = ViewModel.extract_viewmodel_metadata(child_hash)

      child_viewmodel_class =
        association_data.viewmodel_class_for_name(child_metadata.view_name)

      if child_viewmodel_class.nil?
        raise ViewModel::DeserializationError::InvalidAssociationType.new(
                association_data.association_name.to_s,
                child_metadata.view_name,
                blame_reference)
      end

      verify_schema_version!(child_viewmodel_class, child_metadata.schema_version, child_metadata.id) if child_metadata.schema_version

      UpdateData.new(child_viewmodel_class, child_metadata, child_hash, valid_reference_keys)
    end

    private

    def self.reference_only_hash?(hash)
      hash.size == 2 && hash.has_key?(ViewModel::ID_ATTRIBUTE) && hash.has_key?(ViewModel::TYPE_ATTRIBUTE)
    end

    def parse(hash_data, valid_reference_keys)
      hash_data = hash_data.dup

      # handle view pre-parsing if defined
      self.viewmodel_class.pre_parse(viewmodel_reference, metadata, hash_data) if self.viewmodel_class.respond_to?(:pre_parse)
      hash_data.keys.each do |key| # rubocop:disable Style/HashEachMethods
        if self.viewmodel_class.respond_to?(:"pre_parse_#{key}")
          self.viewmodel_class.public_send("pre_parse_#{key}", viewmodel_reference, metadata, hash_data, hash_data.delete(key))
        end
      end

      hash_data.each do |name, value|
        member_data = self.viewmodel_class._members[name]
        case member_data
        when ViewModel::Record::AttributeData
          attributes[name] = value

        when AssociationData
          association_data = member_data

          case
          when value.nil?
            if association_data.collection?
              raise ViewModel::DeserializationError::InvalidSyntax.new(
                      "Invalid collection update value 'nil' for association '#{name}'",
                      blame_reference)
            end
            if association_data.referenced?
              referenced_associations[name] = nil
            else
              associations[name] = nil
            end

          when association_data.referenced?
            if association_data.collection?
              referenced_associations[name] =
                ReferencedCollectionUpdate::Parser
                  .new(association_data, blame_reference, valid_reference_keys)
                  .parse(value)
            else
              # Extract and check reference
              ref = ViewModel.extract_reference_metadata(value)

              unless valid_reference_keys.include?(ref)
                raise ViewModel::DeserializationError::InvalidSharedReference.new(ref, blame_reference)
              end

              referenced_associations[name] = ref
            end
          else
            associations[name] =
              if association_data.collection?
                OwnedCollectionUpdate::Parser
                  .new(association_data, blame_reference, valid_reference_keys)
                  .parse(value)
              else # not a collection
                if value.nil? # rubocop:disable Style/IfInsideElse
                  nil
                else
                  self.class.parse_associated(association_data, blame_reference, valid_reference_keys, value)
                end
              end
          end
        else
          raise ViewModel::DeserializationError::UnknownAttribute.new(name, blame_reference)
        end
      end
    end

    def blame_reference
      ViewModel::Reference.new(self.viewmodel_class, self.id)
    end

    def self.verify_schema_version!(viewmodel_class, schema_version, id)
      unless viewmodel_class.accepts_schema_version?(schema_version)
        raise ViewModel::DeserializationError::SchemaVersionMismatch.new(
                viewmodel_class,
                schema_version,
                ViewModel::Reference.new(viewmodel_class, id))
      end
    end
  end
end
