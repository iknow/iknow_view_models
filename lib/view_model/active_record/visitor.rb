# frozen_string_literal: true

class ViewModel::ActiveRecord::Visitor
  attr_reader :visit_shared

  def initialize(visit_shared: true)
    @visit_shared = visit_shared
  end

  def visit(node, context: nil)
    return unless pre_visit(node, context: context)

    class_name = node.class.name.underscore.gsub('/', '__')
    visit      = :"visit_#{class_name}"
    end_visit  = :"end_visit_#{class_name}"

    visit_children =
      if respond_to?(visit, true)
        self.send(visit, node, context: context)
      else
        true
      end

    if visit_children
      # visit the underlying viewmodel for each association, ignoring any
      # customization
      node.class._members.each do |name, member_data|
        next unless member_data.is_a?(ViewModel::ActiveRecord::AssociationData)
        next if member_data.shared? && !visit_shared
        children = Array.wrap(node._read_association(name))
        children.each do |child|
          if context
            child_context = context.for_child(node, association_name: name, root: member_data.shared?)
          end
          self.visit(child, context: child_context)
        end
      end
    end

    self.send(end_visit, node, context: context) if respond_to?(end_visit, true)

    post_visit(node, context: context)
  end

  # Invoked for all node types before visit, may cancel visit by returning
  # false.
  def pre_visit(_node, context: nil)
    true
  end

  # Invoked for all node types after visit.
  def post_visit(_node, context: nil); end
end
