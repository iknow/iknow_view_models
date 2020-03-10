# frozen_string_literal: true

class ViewModel::ActiveRecord::Visitor
  attr_reader :visit_referenced, :visit_shared, :for_edit

  def initialize(visit_referenced: true, visit_shared: true, for_edit: false)
    @visit_referenced = visit_referenced
    @visit_shared     = visit_shared
    @for_edit         = for_edit
  end

  def visit(view, context: nil)
    reset_state!

    return unless pre_visit(view, context: context)

    run_callback(ViewModel::Callbacks::Hook::BeforeVisit, view, context: context)
    run_callback(ViewModel::Callbacks::Hook::BeforeDeserialize, view, context: context) if for_edit

    class_name = view.class.name.underscore.gsub('/', '__')
    visit      = :"visit_#{class_name}"
    end_visit  = :"end_visit_#{class_name}"

    visit_children =
      if respond_to?(visit, true)
        self.send(visit, view, context: context)
      else
        true
      end

    if visit_children
      # visit the underlying viewmodel for each association, ignoring any
      # customization
      ignored_associations = @ignored_associations
      view.class._members.each do |name, member_data|
        next unless member_data.association?
        next if ignored_associations.include?(name)
        next if member_data.referenced? && !visit_referenced
        next if !member_data.owned? && !visit_shared

        children = Array.wrap(view._read_association(name))
        children.each do |child|
          if context
            child_context = view.context_for_child(name, context: context)
          end
          self.visit(child, context: child_context)
        end
      end
    end

    self.send(end_visit, view, context: context) if respond_to?(end_visit, true)

    if for_edit
      view_changes = changes(view)
      run_callback(ViewModel::Callbacks::Hook::OnChange, view, context: context, changes: view_changes) if view_changes.changed?
      run_callback(ViewModel::Callbacks::Hook::AfterDeserialize, view, context: context, changes: view_changes)
    end

    run_callback(ViewModel::Callbacks::Hook::AfterVisit, view, context: context)

    post_visit(view, context: context)
  end

  # Invoked for all view types before visit, may cancel visit by returning
  # false.
  def pre_visit(_view, context: nil)
    true
  end

  # Invoked for all view types after visit.
  def post_visit(_view, context: nil); end

  # If a context is provided, run the specified callback hook on it
  def run_callback(hook, view, context:, **args)
    context.run_callback(hook, view, **args) if context
  end

  # This method may be overridden by subclasses to specify the changes to be
  # provided to callback hooks for each view. By default returns an empty
  # Changes.
  def changes(_view)
    ViewModel::Changes.new
  end

  private

  def ignore_association!(name)
    @ignored_associations.add(name.to_s)
  end

  def reset_state!
    @ignored_associations = Set.new
  end

end
