# frozen_string_literal: true

require_relative '../../../helpers/arvm_test_utilities'
require_relative '../../../helpers/arvm_test_models'
require_relative '../../../helpers/viewmodel_spec_helpers'

require 'minitest/autorun'

require 'view_model/active_record'

class ViewModel::ActiveRecord::Alias < ActiveSupport::TestCase
  include ARVMTestUtilities
  extend Minitest::Spec::DSL

  include ViewModelSpecHelpers::ParentAndBelongsToChild

  def child_attributes
    super.merge(
      viewmodel: ->(v) do
        add_view_alias 'ChildA'
        add_view_alias 'ChildB'
      end,
    )
  end

  it 'permits association types to be aliased' do
    %w[Child ChildA ChildB].each do |view_alias|
      view = {
        '_type' => viewmodel_class.view_name,
        'child' => { '_type' => view_alias },
      }

      parent = viewmodel_class.deserialize_from_view(view).model
      assert_instance_of(child_model_class, parent.child)
    end
  end
end
