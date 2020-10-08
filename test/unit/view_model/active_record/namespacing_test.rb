# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'
require 'minitest/hooks'

require_relative '../../../helpers/arvm_test_utilities.rb'
require_relative '../../../helpers/arvm_test_models.rb'
require_relative '../../../helpers/viewmodel_spec_helpers.rb'

require 'view_model'
require 'view_model/active_record'

module NSTest
end

class ViewModel::ActiveRecord::NamespacingTest < ActiveSupport::TestCase
  include ViewModelSpecHelpers::ParentAndHasOneChild
  extend Minitest::Spec::DSL

  def namespace
    NSTest
  end

  def model_attributes
    parent_attrs = super

    ViewModel::TestHelpers::ARVMBuilder::Spec.new(
      schema:    parent_attrs.schema,
      viewmodel: parent_attrs.viewmodel,
      model:     ->(_) {
        has_one :child, inverse_of: :model, class_name: 'NSTest::Child', dependent: :destroy
      })
  end

  describe 'inference' do
    it 'assigns a transformed view name from a namespaced class' do
      assert_equal('NSTest.Model', viewmodel_class.view_name)
    end

    it 'can look up a viewmodel by inference from an association to a namespaced model' do
      child_viewmodel_class # test depends on child_viewmodel_class

      assert_equal(viewmodel_class._association_data('child').viewmodel_class,
                   child_viewmodel_class)
    end

    it 'can infer the model class from a namespaced view class name' do
      assert_equal(viewmodel_class.model_class, model_class)
    end
  end

  describe 'access control' do
    include ARVMTestUtilities

    it 'can apply access control policy for namespaced classes' do
      _viewmodel_class = viewmodel_class

      access_control_class =
        Class.new(ViewModel::AccessControl::Tree) do
          view(_viewmodel_class.view_name) do
            visible_unless!('VETO-ERROR-MESSAGE') { true }
          end
        end

      child_viewmodel_class # test depends on child_viewmodel_class

      serialize_context = viewmodel_class.new_serialize_context(
        access_control: access_control_class.new)

      refute_serializes(viewmodel_class,
                        model_class.create!,
                        'VETO-ERROR-MESSAGE',
                        serialize_context: serialize_context)
    end
  end
end
