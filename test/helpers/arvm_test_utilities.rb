require 'active_support'
require 'minitest/hooks'

require 'view_model'
require 'view_model/test_helpers'

require_relative 'query_logging.rb'

ActiveSupport::TestCase.include(Minitest::Hooks)

module ARVMTestUtilities
  extend ActiveSupport::Concern
  include ViewModel::TestHelpers

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
    refhash = {'_type' => viewmodel_class.view_name, 'id' => model.id}
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
    # equivalent to `group_by{|x|x}.map{|k,v| [k, v.length]}.to_h`
    enum.each_with_object(Hash.new(0)) do |x, counts|
      counts[x] += 1
    end
  end

  def enable_logging!
    if ENV["DEBUG"]
      ActiveRecord::Base.logger = Logger.new(STDERR)
    end
  end



end
