class ViewModel::ActiveRecord::Visitor
  def visit(node)
    pre_visit(node)

    class_name = node.class.name.underscore
    visit      = :"visit_#{class_name}"
    end_visit  = :"end_visit_#{class_name}"

    visit_children =
      if respond_to?(visit, true)
        self.send(visit, node)
      else
        true
      end

    if visit_children
      # visit the underlying viewmodel for each association, ignoring any
      # customization
      node.class._members.each do |name, member_data|
        next unless member_data.is_a?(ViewModel::ActiveRecord::AssociationData)
        children = Array.wrap(node.read_association(name))
        children.each do |child|
          self.visit(child)
        end
      end
    end

    self.send(end_visit, node) if respond_to?(end_visit, true)

    post_visit(node)
  end

  def pre_visit(node)
  end

  def post_visit(node)
  end
end
