require_relative "../../../helpers/arvm_test_utilities.rb"
require_relative "../../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "view_model/active_record"
require "persistent_enum"

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
        attribute :product_type
        acts_as_enum :product_type
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
        attribute :product_type, read_only: true
        acts_as_enum :product_type
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
