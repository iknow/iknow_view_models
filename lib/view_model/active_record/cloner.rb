# Simple visitor for cloning models through the tree structure defined by
# ViewModel::ActiveRecord. Owned associations will be followed and cloned, while
# shared associations will be copied directly. Attributes (including association
# foreign keys not covered by ViewModel `association`s) will be copied from the
# original.
#
# To customize, subclasses may define methods `visit_x_view(node, new_model)`
# for each type they wish to affect. These callbacks may update attributes of
# the new model, and additionally can call `ignore!` or
# `ignore_association!(name)` to prune the current model or the target of the
# named association from the cloned tree.
class ViewModel::ActiveRecord::Cloner
  def clone(node)
    reset_state!

    new_model = node.model.dup

    pre_visit(node, new_model)
    return nil if ignored?

    node.class.name.try do |class_name|
      visit = :"visit_#{class_name.underscore.gsub('/', '__')}"

      if respond_to?(visit, true)
        self.send(visit, node, new_model)
        return nil if ignored?
      end
    end

    # visit the underlying viewmodel for each association, ignoring any
    # customization
    node.class._members.each do |name, association_data|
      next unless association_data.is_a?(ViewModel::ActiveRecord::AssociationData)

      if association_ignored?(name)
        new_associated = nil
      else
        # Load the record associated with the old model
        reflection = association_data.direct_reflection
        associated = node.model.public_send(reflection.name)

        if associated.nil?
          new_associated = nil
        elsif association_data.shared? && !association_data.through?
          # simply attach the associated target to the new model
          new_associated = associated
        else
          # Otherwise descend into the child, and attach the result
          vm_class =
            case
            when association_data.through?
              # descend into the synthetic join table viewmodel
              association_data.direct_viewmodel
            when association_data.collection?
              association_data.viewmodel_class
            else
              association_data.viewmodel_class_for_model!(associated.class)
            end

          new_associated =
            if ViewModel::Utils.array_like?(associated)
              associated.map { |m| clone(vm_class.new(m)) }.compact
            else
              clone(vm_class.new(associated))
            end
        end
      end

      new_association = new_model.association(reflection.name)
      new_association.replace(new_associated)
    end

    new_model
  end

  def pre_visit(node, new_model)
  end

  private

  def reset_state!
    @ignored = false
    @ignored_associations = Set.new
  end

  def ignore!
    @ignored = true
  end

  def ignore_association!(name)
    @ignored_associations.add(name.to_s)
  end

  def ignored?
    @ignored
  end

  def association_ignored?(name)
    @ignored_associations.include?(name.to_s)
  end
end
