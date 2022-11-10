# frozen_string_literal: true

require 'active_support'
require 'minitest/hooks'

require 'view_model'
require 'view_model/test_helpers'

unless ViewModel::Config.configured?
  ViewModel::Config.configure! do
    debug_deserialization true
  end
end

require_relative 'query_logging'

ActiveSupport::TestCase.include(Minitest::Hooks)

module ARVMTestUtilities
  extend ActiveSupport::Concern
  include ViewModel::TestHelpers
  using ViewModel::Utils::Collections

  def self.included(klass)
    klass.include(QueryLogging)
  end

  def initialize(*)
    @viewmodels = []
    super
  end

  def after_all
    @viewmodels.each(&:teardown)
    @viewmodels.clear
    super
  end

  def teardown
    ActiveRecord::Base.logger = nil
    super
  end

  def build_viewmodel(name, &block)
    @viewmodels << ViewModel::TestHelpers::ARVMBuilder.new(name, &block)
  end

  def serialize_with_references(serializable, serialize_context: ViewModelBase.new_serialize_context)
    super(serializable, serialize_context: serialize_context)
  end

  def serialize(serializable, serialize_context: ViewModelBase.new_serialize_context)
    super(serializable, serialize_context: serialize_context)
  end

  # Construct an update hash that references an existing model. Does not include
  # any of the model's attributes or association.
  def update_hash_for(viewmodel_class, model)
    refhash = { '_type' => viewmodel_class.view_name, 'id' => model.id }
    yield(refhash) if block_given?
    refhash
  end

  # Test helper: update a model by constructing a new view hash
  # TODO the body of this is growing longer and is mostly the same as by `alter_by_view!`.
  def set_by_view!(viewmodel_class, model)
    models = Array.wrap(model)

    data = models.map { |m| update_hash_for(viewmodel_class, m) }
    refs = {}

    if model.is_a?(Array)
      yield(data, refs)
    else
      yield(data.first, refs)
    end

    begin
      deserialize_context = ViewModelBase::DeserializeContext.new

      viewmodel_class.deserialize_from_view(
        data, references: refs, deserialize_context: ViewModelBase::DeserializeContext.new)

      deserialize_context
    ensure
      models.each { |m| m.reload }
    end
  end

  def count_all(enum)
    enum.count_by { |x| x }
  end

  def enable_logging!
    if ENV['DEBUG']
      ActiveRecord::Base.logger = Logger.new($stderr)
    end
  end

  def assert_serializes(vm, model, serialize_context: vm.new_serialize_context)
    h = vm.new(model).serialize_to_hash(serialize_context: serialize_context)
    assert_kind_of(Hash, h)
    refs = serialize_context.serialize_references_to_hash
    assert_kind_of(Hash, refs)
  end

  def refute_serializes(vm, model, message = nil, serialize_context: vm.new_serialize_context)
    ex = assert_raises(ViewModel::AccessControlError) do
      vm.new(model).serialize_to_hash(serialize_context: serialize_context)
      serialize_context.serialize_references_to_hash
    end
    assert_match(message, ex.message) if message
    ex
  end

  def assert_deserializes(vm, model,
                          deserialize_context: vm.new_deserialize_context,
                          serialize_context: vm.new_serialize_context,
                          &block)
    alter_by_view!(vm, model,
                   deserialize_context: deserialize_context,
                   serialize_context:   serialize_context,
                   &block)
  end

  def refute_deserializes(vm, model, message = nil,
                          deserialize_context: vm.new_deserialize_context,
                          serialize_context: vm.new_serialize_context,
                          &block)
    ex = assert_raises(ViewModel::AccessControlError) do
      alter_by_view!(vm, model,
                     deserialize_context: deserialize_context,
                     serialize_context:   serialize_context,
                     &block)
    end
    assert_match(message, ex.message) if message
    ex
  end

  class FupdateBuilder
    class DSL
      def initialize(builder)
        @builder = builder
      end

      def append(hashes, **rest)
        @builder.append_action(
          type:   ViewModel::ActiveRecord::FunctionalUpdate::Append,
          values: hashes,
          **rest)
      end

      def remove(hashes)
        @builder.append_action(
          type:   ViewModel::ActiveRecord::FunctionalUpdate::Remove,
          values: hashes)
      end

      def update(hashes)
        @builder.append_action(
          type:   ViewModel::ActiveRecord::FunctionalUpdate::Update,
          values: hashes)
      end
    end

    def initialize
      @actions = []
    end

    def append_action(type:, values:, **rest)
      @actions.push(
        {
          ViewModel::ActiveRecord::TYPE_ATTRIBUTE   => type::NAME,
          ViewModel::ActiveRecord::VALUES_ATTRIBUTE => values,
        }.merge(rest.transform_keys(&:to_s)),
      )
    end

    def build!(&block)
      DSL.new(self).instance_eval(&block)

      {
        ViewModel::ActiveRecord::TYPE_ATTRIBUTE    =>
          ViewModel::ActiveRecord::FUNCTIONAL_UPDATE_TYPE,

        ViewModel::ActiveRecord::ACTIONS_ATTRIBUTE =>
          @actions,
      }
    end
  end

  def build_fupdate(attrs = {}, &block)
    FupdateBuilder.new.build!(&block).merge(attrs)
  end

  def each_hook_span(trace)
    return enum_for(:each_hook_span, trace) unless block_given?

    hook_nesting = []

    trace.each_with_index do |t, i|
      case t.hook
      when ViewModel::Callbacks::Hook::OnChange,
        ViewModel::Callbacks::Hook::BeforeValidate
        # ignore
      when ViewModel::Callbacks::Hook::BeforeVisit,
        ViewModel::Callbacks::Hook::BeforeDeserialize
        hook_nesting.push([t, i])

      when ViewModel::Callbacks::Hook::AfterVisit,
        ViewModel::Callbacks::Hook::AfterDeserialize
        (nested_top, nested_index) = hook_nesting.pop

        unless nested_top.hook.name == t.hook.name.sub(/^After/, 'Before')
          raise "Invalid nesting, processing '#{t.hook.name}', expected matching '#{nested_top.hook.name}'"
        end

        unless nested_top.view == t.view
          raise "Invalid nesting, processing '#{t.hook.name}', " \
                  "expected viewmodel '#{t.view}' to match '#{nested_top.view}'"
        end

        yield t.view, (nested_index..i), t.hook.name.sub(/^After/, '')

      else
        raise 'Unexpected hook type'
      end
    end
  end

  def show_span(view, range, hook)
    "#{view.class.name}(#{view.id}) #{range} #{hook}"
  end

  def enclosing_hooks(spans, inner_range)
    spans.select do |_view, range, _hook|
      inner_range != range && range.cover?(inner_range.min) && range.cover?(inner_range.max)
    end
  end

  def assert_all_hooks_nested_inside_parent_hook(trace)
    spans = each_hook_span(trace).to_a

    spans.reject { |view, _range, _hook| view.class == ParentView }.each do |view, range, hook|
      enclosing_spans = enclosing_hooks(spans, range)

      enclosing_parent_hook = enclosing_spans.detect do |other_view, _other_range, other_hook|
        other_hook == hook && other_view.class == ParentView
      end

      next if enclosing_parent_hook

      self_str      = show_span(view, range, hook)
      enclosing_str = enclosing_spans.map { |ov, ora, oh| show_span(ov, ora, oh) }.join("\n")
      assert_not_nil(
        enclosing_parent_hook,
        "Invalid nesting of hook: #{self_str}\nEnclosing hooks:\n#{enclosing_str}")
    end
  end
end
