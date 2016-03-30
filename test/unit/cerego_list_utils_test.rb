require 'iknow_list_utils'

require 'minitest/autorun'

class TestBSearch < Minitest::Test
  using IknowListUtils

  def test_bsearch_singleton
    assert_equal(1, [1].bsearch_max { true })
    assert_equal(nil, [1].bsearch_max { false })
  end

  def test_bsearch_near
    assert_equal(2, [1, 2].bsearch_max { true })
    assert_equal(nil, [1, 2].bsearch_max { false })
    assert_equal(1, [1, 2].bsearch_max { |x| x < 2 })
  end

  def test_bsearch_general
    assert_equal(nil, [1,2,3].bsearch_max(1, 0))

    arr = (1..100).to_a
    2.upto(arr.count) do |i|
      assert_equal(i, arr.bsearch_max { |x| x <= i })
    end
  end

  def test_longest_rising_sequence
    assert_equal([], [].longest_rising_sequence)

    assert_equal([1], [2, 1].longest_rising_sequence)

    assert_equal([1, 2, 3], [1, 4, 2, 3].longest_rising_sequence)

    assert_equal([1, 3, 4], [1, 1, 1, 3, 3, 3, 3, 4].longest_rising_sequence,
                 "duplicate entries allowed; return is monotonically increasing")

    assert_equal([2, 1],
                 [2, 1].longest_rising_sequence { |x, y| y <=> x })

    assert_equal([4, 3],
                 [1, 4, 2, 3].longest_rising_sequence { |x, y| y <=> x })

    assert_equal([[1], [2], [3]],
                 [[1], [4], [2], [3]].longest_rising_sequence_by { |x| x.first })
  end
end

