# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'
require 'minitest/hooks'

require_relative '../../helpers/arvm_test_utilities'
require_relative '../../helpers/arvm_test_models'
require_relative '../../helpers/viewmodel_spec_helpers'

require 'view_model'
require 'view_model/active_record'

class ViewModel
  class RegistryTest < ActiveSupport::TestCase
    using ViewModel::Utils::Collections
    include ARVMTestUtilities
    extend Minitest::Spec::DSL
    include ViewModelSpecHelpers::ParentAndBelongsToChild

    before(:each) do
      ViewModel::Registry.clear_removed_classes!
    end

    it 'registers the views' do
      assert_equal(ViewModel::Registry.for_view_name(view_name), viewmodel_class)
      assert_equal(ViewModel::Registry.for_view_name(child_view_name), child_viewmodel_class)
    end

    it 'enumerates the views' do
      assert_contains_exactly([ViewModel::ErrorView, viewmodel_class, child_viewmodel_class], ViewModel::Registry.all)
    end

    it 'enumerates the root views' do
      assert_contains_exactly([viewmodel_class], ViewModel::Registry.roots)
    end
  end
end
