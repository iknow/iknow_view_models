class ActiveRecordViewModel
  class UpdateData
    attr_accessor :viewmodel_class, :id, :attributes, :associations, :referenced_associations

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
      ref_counts = root_updates.each_with_object(Hash.new(0)) do |upd, counts|
        counts[[upd.viewmodel_class, upd.id]] += 1 if id
      end.delete_if { |_, count| count == 1 }

      if ref_counts.present?
        raise ViewModel::DeserializationError.new("Duplicate entries in specification: '#{ref_counts.keys.to_h}'")
      end

      # Construct reference UpdateData
      referenced_updates = referenced_subtree_hashes.map_values do |subtree_hash|
        viewmodel_name, id = extract_viewmodel_metadata(subtree_hash)
        viewmodel_class    = ActiveRecordViewModel.for_view_name(viewmodel_name)

        UpdateData.new(viewmodel_class, id, subtree_hash, valid_reference_keys)
      end

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

    private

    def parse(hash_data, valid_reference_keys)
      hash_data.each do |name, value|
        case self.viewmodel.class._members[name]
        when :attribute
          attributes[name] = value

        when :association
          association_data = self.viewmodel.class._association_data(association_name)
          if association_data.shared?
            # Extract and check reference
            ref = UpdateData.extract_reference_metadata(value)

            unless valid_reference_keys.include?(ref)
              raise ViewModel::DeserializationError.new("Could not parse unresolvable reference '#{ref}'")
            end

            referenced_associations[name] = ref # currently can only be singular (don't support has-many-through yet).

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
