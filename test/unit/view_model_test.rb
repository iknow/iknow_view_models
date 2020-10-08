require 'bundler/setup'
Bundler.require

require 'minitest/autorun'

class DefaultViewModel < ViewModel
  self.view_name = 'DefaultViewModel'
  attributes :foo, :bar
end

class TestViewModel < ViewModel
  self.view_name = 'TestViewModel'

  attributes :val
  def serialize_view(json, **_options)
    json.name val
  end
end

class ViewModel::ActiveRecordTest < ActiveSupport::TestCase
  def test_serialize
    s = TestViewModel.new('a')
    assert_equal(TestViewModel.serialize_to_hash(s),
                 { 'name' => 'a' })
  end

  def test_default_serialize
    s = DefaultViewModel.new('a', 1)
    assert_equal(TestViewModel.serialize_to_hash(s),
                 { 'foo' => 'a', 'bar' => 1 })
  end

  def test_default_serialize_array
    s = DefaultViewModel.new('a', [1,2])
    assert_equal(TestViewModel.serialize_to_hash(s),
                 { 'foo' => 'a', 'bar' => [1,2] })
  end

  def test_default_serialize_hash
    s = DefaultViewModel.new('a', { 'x' => 'y' })
    assert_equal(DefaultViewModel.serialize_to_hash(s),
                 { 'foo' => 'a', 'bar' => { 'x' => 'y' } })
  end

  def test_default_serialize_empty_hash
    s = DefaultViewModel.new('a', {})
    assert_equal(DefaultViewModel.serialize_to_hash(s),
                 { 'foo' => 'a', 'bar' => {} })
  end

  def test_default_serialize_viewmodel
    s = DefaultViewModel.new('a', DefaultViewModel.new(1, 2))
    assert_equal(DefaultViewModel.serialize_to_hash(s),
                 { 'foo' => 'a', 'bar' => { 'foo' => 1, 'bar' => 2 } })
  end

  def test_default_serialize_array_of_viewmodel
    s = DefaultViewModel.new('a', [TestViewModel.new('x'), TestViewModel.new('y')])
    assert_equal(DefaultViewModel.serialize_to_hash(s),
                 { 'foo' => 'a', 'bar' => [{'name' => 'x'}, {'name' => 'y'}] })
  end
end
