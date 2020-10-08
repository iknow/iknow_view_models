# frozen_string_literal: true

require_relative '../../../helpers/arvm_test_utilities.rb'
require_relative '../../../helpers/arvm_test_models.rb'

require 'minitest/autorun'

require 'view_model/active_record'

class ViewModel::ActiveRecord::VersionTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:ChildA) do
      define_schema {}
      define_model do
        has_one :parent, inverse_of: :child
      end
      define_viewmodel do
        self.schema_version = 10
      end
    end

    build_viewmodel(:Target) do
      define_schema {}
      define_model do
        has_one :parent, inverse_of: :target
      end
      define_viewmodel do
        root!
        self.schema_version = 20
      end
    end

    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :child_type
        t.integer :child_id
        t.integer :target_id
      end
      define_model do
        belongs_to :child, polymorphic: true
        belongs_to :target
      end
      define_viewmodel do
        self.schema_version = 5
        root!
        association :child, viewmodels: [:ChildA]
        association :target
      end
    end
  end

  def setup
    super
    @parent_with_a = Parent.create(child: ChildA.new, target: Target.new)
  end

  def test_schema_versions_reflected_in_output
    data, refs = serialize_with_references(ParentView.new(@parent_with_a))

    target_ref = refs.keys.first

    assert_equal({ '_type'    => 'Parent',
                   'id'       => @parent_with_a.id,
                   '_version' => 5,
                   'child'    => {
                     '_type'    => 'ChildA',
                     'id'       => @parent_with_a.child.id,
                     '_version' => 10,
                   },
                   'target' => { '_ref' => target_ref } },
                 data)

    assert_equal({ target_ref =>
                     {
                       '_type'    => 'Target',
                       'id'       => @parent_with_a.target.id,
                       '_version' => 20
                     } },
                 refs)
  end

  def test_regular_version_verification
    ex = assert_raise(ViewModel::DeserializationError::SchemaVersionMismatch) do
      ParentView.deserialize_from_view(
        { '_type'    => 'Parent',
          '_new'     => true,
          '_version' => 99 },)
    end
    assert_match(/schema version/, ex.message)
  end

  def test_polymorphic_version_verification
    ex = assert_raise(ViewModel::DeserializationError::SchemaVersionMismatch) do
      ParentView.deserialize_from_view(
        { '_type' => 'Parent',
          '_new'  => true,
          'child' => {
            '_type'    => 'ChildA',
            '_version' => 99,
          } })
    end
    assert_match(/schema version/, ex.message)
  end

  def test_shared_parse_version_verification
    ex = assert_raise(ViewModel::DeserializationError::SchemaVersionMismatch) do
      ParentView.deserialize_from_view(
        { '_type'  => 'Parent',
          '_new'   => true,
          'target' => { '_ref' => 't1' },
        },
        references: { 't1' => {
          '_type'    => 'Target',
          '_new'     => true,
          '_version' => 99,
        } })
    end
    assert_match(/schema version/, ex.message)
  end
end
