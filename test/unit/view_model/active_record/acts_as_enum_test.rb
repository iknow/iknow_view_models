require_relative "../../../helpers/arvm_test_utilities.rb"
require_relative "../../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "view_model/active_record"
require "persistent_enum"

class EnumValueView < ViewModel
  attribute :enum_value
  self.lock_attribute_inheritance

  def serialize_view(json, serialize_context:)
    json.merge! enum_value&.enum_constant
  end

  def self.deserialize_from_view(json_data, deserialize_context:)
    enum_value = self.enum_class.value_of(json_data)
    if enum_value.nil?
      raise ViewModel::DeserializationError.new("Invalid enumeration constant '#{value}'", deserialize_context.parent.blame_reference)
    end
    self.new(enum_value)
  end

  def ==(other)
    self.class == other.class &&
      self.enum_value == other.enum_value
  end

  alias :eql? :==

  def self.for_enum(enum_class)
    Class.new(self) do
      define_singleton_method(:enum_class) { enum_class }
    end
  end
end

class ViewModel::ActiveRecord::ActsAsEnumTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:ProductType) do
      define_schema do |t|
        t.string :name, null: false
      end
      define_model do
        acts_as_enum %w[Liquid Solid]
      end
      no_viewmodel
    end

    build_viewmodel(:Product) do
      define_schema do |t|
        t.references :product_type, null: false, index: true, foreign_key: true
      end
      define_model do
        belongs_to_enum :product_type
      end
      define_viewmodel do
        attribute :product_type, using: EnumValueView.for_enum(ProductType)
      end
    end

    build_viewmodel(:Category) do
      define_schema do |t|
        t.references :product_type, null: false, index: true, foreign_key: true
      end
      define_model do
        belongs_to_enum :product_type
      end
      define_viewmodel do
        attribute :product_type, read_only: true, using: EnumValueView.for_enum(ProductType)
      end
    end
  end

  def setup
    @product1      = Product.create!(product_type: ProductType::LIQUID)
    @product1_view = ProductView.new(@product1).to_hash

    @category1      = Category.create!(product_type: ProductType::LIQUID)
    @category1_view = CategoryView.new(@category1).to_hash
  end

  def test_serialize
    assert_equal('Liquid', @product1_view['product_type'], "Value serialised as string")
  end

  def test_deserialize
    @product1_view['product_type'] = 'Solid'
    ProductView.deserialize_from_view(@product1_view)
    @product1.reload
    assert_equal(ProductType::SOLID, @product1.product_type)
  end

  def test_deserialize_readonly
    @category1_view['product_type'] = 'Solid'
    ex = assert_raises(ViewModel::DeserializationError) do
      CategoryView.deserialize_from_view(@category1_view)
    end
    assert_match(/read only/, ex.message)
  end
end
