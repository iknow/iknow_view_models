class ActiveRecordViewModel
  class UpdateData
    attr_accessor :viewmodel_class, :id, :attributes, :associations, :referenced_associations

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

    def self.parse_hashes(root_subtree_hashes, referenced_subtree_hashes = {})
      valid_reference_keys = referenced_subtree_hashes.keys.to_set

      valid_reference_keys.each do |ref|
        raise "Invalid reference string: #{ref}" unless ref.is_a?(String)
      end

      # Construct root UpdateData
      root_updates = root_subtree_hashes.map do |subtree_hash|
        viewmodel_name, id = extract_viewmodel_metadata(subtree_hash)
        viewmodel_class    = ActiveRecordViewModel.for_view_name(viewmodel_name)

        UpdateData.new(viewmodel_class, id, subtree_hash, valid_reference_keys)
      end

      # Ensure that no root is referred to more than once
      check_duplicates(root_updates, type: "root") { |upd| [upd.viewmodel_class, upd.id] if upd.id }

      # Construct reference UpdateData
      referenced_updates = referenced_subtree_hashes.transform_values do |subtree_hash|
        viewmodel_name, id = extract_viewmodel_metadata(subtree_hash)
        viewmodel_class    = ActiveRecordViewModel.for_view_name(viewmodel_name)

        UpdateData.new(viewmodel_class, id, subtree_hash, valid_reference_keys)
      end

      check_duplicates(referenced_updates, type: "reference") { |ref, upd| [upd.viewmodel_class, upd.id] if upd.id }

      return root_updates, referenced_updates
    end

    def self.extract_viewmodel_metadata(hash)
      unless hash.is_a?(Hash)
        raise ViewModel::DeserializationError.new("Invalid data to deserialize - not a hash: '#{hash.inspect}'")
      end

      unless hash.has_key?(ActiveRecordViewModel::TYPE_ATTRIBUTE)
        raise ViewModel::DeserializationError.new("Missing '#{ActiveRecordViewModel::TYPE_ATTRIBUTE}' field in update hash: '#{hash.inspect}'")
      end

      id        = hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
      type_name = hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)
      return type_name, id
    end

    def self.extract_reference_metadata(hash)
      unless hash.is_a?(Hash)
        raise ViewModel::DeserializationError.new("Invalid data to deserialize - not a hash: '#{hash.inspect}'")
      end

      unless hash.size == 1
        raise ViewModel::DeserializationError.new("Invalid reference hash data - must not contain keys besides '#{ActiveRecordViewModel::REFERENCE_ATTRIBUTE}': #{hash.keys.inspect}")
      end

      unless hash.has_key?(ActiveRecordViewModel::REFERENCE_ATTRIBUTE)
        raise ViewModel::DeserializationError.new("Invalid reference hash data - '#{ActiveRecordViewModel::REFERENCE_ATTRIBUTE}' attribute missing: #{hash.inspect}")
      end

      hash.delete(ActiveRecordViewModel::REFERENCE_ATTRIBUTE)
    end

    def self.check_duplicates(arr, type:)
      # Ensure that no root is referred to more than once
      ref_counts = arr.each_with_object(Hash.new(0)) do |el, counts|
        key = yield(el)
        counts[key] += 1 unless key.nil?
      end.delete_if { |_, count| count == 1 }

      if ref_counts.present?
        raise ViewModel::DeserializationError.new("Duplicate #{type}(s) specified: '#{ref_counts.keys.to_h}'")
      end
    end

    def initialize(viewmodel_class, id, hash_data, valid_reference_keys)
      self.viewmodel_class = viewmodel_class
      self.id = id
      self.attributes = {}
      self.associations = {}
      self.referenced_associations = {}

      parse(hash_data, valid_reference_keys)
    end

    def self.empty_update_for(viewmodel)
      self.new(viewmodel.class, viewmodel.id, {}, [])
    end

    def association_dependencies(referenced_updates)
      deps = {}

      associations.each do |assoc_name, assoc_update|
        association_data = self.viewmodel_class._association_data(assoc_name)

        assoc_deps =
          case
          when assoc_update.nil?
            {}
          when association_data.polymorphic?
            # AR preloader doesn't allow us to specify different nested includes
            # per polymorphic type. This means we can't continue eager-loading
            # (in the same step) beyond a polymorphic association. For now, just
            # stop and go lazy.
            {}
          when association_data.collection?
            assoc_update.map { |upd| upd.association_dependencies(referenced_updates) }
                        .inject({}) { |acc, dep| acc.deep_merge(dep) }
          else
            assoc_update.association_dependencies(referenced_updates)
          end

        deps[assoc_name] = assoc_deps
      end

      referenced_associations.each do |assoc_name, reference|
        association_data = self.viewmodel_class._association_data(assoc_name)

        case
        when reference.nil?
          {}
        when association_data.collection?
          reference.map { |ref| referenced_updates[ref].association_dependencies(referenced_updates) }
                   .inject({}) { |acc, dep| acc.deep_merge(dep) }
        else
          deps[assoc_name] = referenced_updates[reference].association_dependencies(referenced_updates)
        end
      end

      deps
    end

    private

    def parse(hash_data, valid_reference_keys)
      hash_data = self.viewmodel_class.pre_parse(hash_data) if self.viewmodel_class.respond_to?(:pre_parse)

      hash_data.each do |name, value|
        value = self.viewmodel_class.public_send("pre_parse_#{name}", value) if self.viewmodel_class.respond_to?(:"pre_parse_#{name}")

        case self.viewmodel_class._members[name]
        when :attribute
          attributes[name] = value

        when :association
          association_data = self.viewmodel_class._association_data(name)
          case
          when value.nil?
            associations[name] = nil

          when association_data.through?
            referenced_associations[name] = value.map do |ref_value|
              ref = UpdateData.extract_reference_metadata(ref_value)
              unless valid_reference_keys.include?(ref)
                raise ViewModel::DeserializationError.new("Could not parse unresolvable reference '#{ref}'")
              end
              ref
            end

          when association_data.shared?
            # Extract and check reference
            ref = UpdateData.extract_reference_metadata(value)

            unless valid_reference_keys.include?(ref)
              raise ViewModel::DeserializationError.new("Could not parse unresolvable reference '#{ref}'")
            end

            referenced_associations[name] = ref

          else
            # Recurse into child
            parse_association = ->(child_hash) do
              child_viewmodel_name, child_id = UpdateData.extract_viewmodel_metadata(child_hash)
              child_viewmodel_class          = association_data.viewmodel_class_for_name(child_viewmodel_name)

              UpdateData.new(child_viewmodel_class, child_id, child_hash, valid_reference_keys)
            end

            if association_data.collection?
              unless value.is_a?(Array)
                raise ViewModel::DeserializationError.new("Could not parse non-array collection association")
              end

              associations[name] = value.map { |child_hash| parse_association.(child_hash) }
            else
              associations[name] =
                if value.nil?
                  nil
                else
                  parse_association.(value)
                end
            end
          end
        else
          raise "Could not parse unknown attribute/association #{name} in viewmodel #{viewmodel_class.view_name}"
        end
      end
    end

  end
end
