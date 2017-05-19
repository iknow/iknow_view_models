##
# Helpers useful for writing tests for viewmodel implementations
module ViewModel::TestHelpers
  require 'view_model/test_helpers/arvm_builder'
  extend ActiveSupport::Concern

  def serialize_with_references(serializable, serialize_context: ViewModel.new_serialize_context)
    data = ViewModel.serialize_to_hash(serializable, serialize_context: serialize_context)
    references = serialize_context.serialize_references_to_hash
    return data, references
  end

  def serialize(serializable, serialize_context: ViewModel.new_serialize_context)
    data, _ = serialize_with_references(serializable, serialize_context: serialize_context)
    data
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
      result = viewmodel_class.deserialize_from_view(
        data, references: refs, deserialize_context: deserialize_context)

      result.each do |vm|
        assert_consistent_record(vm)
      end

      result = result.first unless model.is_a?(Array)

      models.each { |m| m.reload }

      return result, deserialize_context
    end
  end

  private

  def assert_consistent_record(viewmodel, been_there: Set.new)
    return if been_there.include?(viewmodel.model)
    been_there << viewmodel.model

    if viewmodel.is_a?(ViewModel::ActiveRecord)
      assert_model_represents_database(viewmodel.model, been_there: been_there)
    elsif viewmodel.is_a?(ViewModel::Record)
      viewmodel.class._members.each do |name, attribute_data|
        if attribute_data.attribute_viewmodel
          assert_consistent_record(viewmodel.send(name), been_there: been_there)
        end
      end
    end
  end

  def assert_model_represents_database(model, been_there: Set.new)
    return if been_there.include?(model)
    been_there << model

    refute(model.new_record?, 'model represents database entity')
    refute(model.changed?, 'model is fully persisted')

    database_model = model.class.find(model.id)

    assert_equal(database_model.attributes,
                 model.attributes,
                 'in memory attributes match database attributes')

    model.class.reflections.each do |_, reflection|
      association = model.association(reflection.name)

      next unless association.loaded?

      case
      when association.target == nil
        assert_nil(database_model.association(reflection.name).target,
                   'in memory nil association matches database')
      when reflection.collection?
        association.target.each do |associated_model|
          assert_model_represents_database(associated_model, been_there: been_there)
        end
      else
        assert_model_represents_database(association.target, been_there: been_there)
      end

    end
  end
end
