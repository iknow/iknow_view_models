class ActiveRecordViewModel::Visitor
  def visit(node)
    pre_visit(node)

    class_name = node.class.name.underscore
    visit      = :"visit_#{class_name}"
    end_visit  = :"end_visit_#{class_name}"

    visit_children =
      if method_defined?(visit)
        self.public_send(visit, node)
      else
        true
      end

    if visit_children
      # visit the underlying viewmodel for each association, ignoring any
      # customization
      node.class._associations.each do |name, association_data|
        children = Array.wrap(node.read_association(name))
        children.each do |child|
          self.visit(child)
        end
      end
    end

    self.public_send(end_visit, node) if method_defined?(end_visit)

    post_visit(node)
  end

  def pre_visit(node)
  end

  def post_visit(node)
  end
end
