require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"
require "counter_culture"

class ActiveRecordViewModel::CounterTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:Category) do
      define_schema do |t|
        t.string :name
        t.integer :products_count, :null => false, :default => 0
      end

      define_model do
        has_many :products, dependent: :destroy
      end

      define_viewmodel do
        association :products
      end
    end

    build_viewmodel(:Product) do
      define_schema do |t|
        t.string :name
        t.references :category, :foreign_key => true
      end

      define_model do
        belongs_to :category, counter_cache: true
      end

      define_viewmodel do
        attribute :name
      end
    end

  end

  def setup
    super
    @category1 = Category.create(name: 'c1', products: [Product.new(name: 'p1')])
    enable_logging!
  end

  def test_counter_cache_create
    alter_by_view!(Views::Category, @category1) do |view, refs|
      view['products'] << {'_type' => 'Product'}
    end
    assert_equal(2, @category1.products_count)
  end

  def test_counter_cache_move
    @category2 = Category.create(name: 'c2')
    alter_by_view!(Views::Category, [@category1, @category2]) do |(c1view, c2view), refs|
      c2view['products'] = c1view['products']
      c1view['products'] = []
    end
    assert_equal(0, @category1.products_count)
    assert_equal(1, @category2.products_count)
  end

  def test_counter_cache_delete
    alter_by_view!(Views::Category, @category1) do |view, refs|
      view['products'] = []
    end
    assert_equal(0, @category1.products_count)
  end

  def test_counter_culture_wat
    cat = Category.create(name: 'c1', products: [Product.new(name: 'p1')])
    assert_equal(1, cat.products_count)
  end
end
