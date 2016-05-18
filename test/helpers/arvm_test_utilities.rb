require 'active_support'
require 'minitest/hooks'

require_relative 'query_logging.rb'

ActiveSupport::TestCase.include(Minitest::Hooks)

module ARVMTestUtilities
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

  def setup
    super

    # Enable logging only during the test body. The test must do any setup in
    # their +setup+ method *before* calling +super+.
    ActiveRecord::Base.logger = Logger.new(STDOUT)
  end

  def teardown
    ActiveRecord::Base.logger = nil
  end

  def build_viewmodel(name, &block)
    @viewmodels << ARVMBuilder.new(name, &block)
  end

  def serialize_with_references(serializable, serialize_context: Views::ApplicationBase.new_serialize_context)
    data = ViewModel.serialize_to_hash(serializable, serialize_context: serialize_context)
    references = serialize_context.serialize_references_to_hash
    return data, references
  end

  def serialize(serializable, serialize_context: Views::ApplicationBase.new_serialize_context)
    data, _ = serialize_with_references(serializable, serialize_context: serialize_context)
    data
  end

  # Construct an update hash that references an existing model. Does not include
  # any of the model's attributes or association.
  def update_hash_for(viewmodel_class, model)
    refhash = {'_type' => viewmodel_class.view_name, 'id' => model.id}
    yield(refhash) if block_given?
    refhash
  end

  # Test helper: update a model by manipulating the full view hash
  def alter_by_view!(viewmodel_class, model,
                     serialize_context:   viewmodel_class.new_serialize_context,
                     deserialize_context: viewmodel_class.new_deserialize_context)

    models = Array.wrap(model)

    data, refs = serialize_with_references(models.map { |m| viewmodel_class.new(m) }, serialize_context: serialize_context)

    if model.is_a?(Array)
      yield(data, refs)
    else
      yield(data.first, refs)
    end

    begin
      viewmodel_class.deserialize_from_view(
        data, references: refs, deserialize_context: deserialize_context)

      deserialize_context
    ensure
      models.each { |m| m.reload }
    end
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
      deserialize_context = Views::ApplicationBase::DeserializeContext.new

      viewmodel_class.deserialize_from_view(
        data, references: refs, deserialize_context: Views::ApplicationBase::DeserializeContext.new)

      deserialize_context
    ensure
      models.each { |m| m.reload }
    end
  end

  def count_all(enum)
    # equivalent to `group_by{|x|x}.map{|k,v| [k, v.length]}.to_h`
    enum.each_with_object(Hash.new(0)) do |x, counts|
      counts[x] += 1
    end
  end

end
