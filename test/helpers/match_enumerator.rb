# frozen_string_literal: true

# From https://stackoverflow.com/a/41293357
module MiniTest::Assertions
  class MatchEnumerator
    def initialize(expected, actual)
      @expected = expected
      @actual = actual
    end

    def match
      return result, message
    end

    def result
      return false unless @actual.respond_to? :to_a
      @extra_items = difference_between_enumerators(@actual, @expected)
      @missing_items = difference_between_enumerators(@expected, @actual)
      @extra_items.empty? & @missing_items.empty?
    end

    def message
      if @actual.respond_to? :to_a
        message = "expected collection contained: #{safe_sort(@expected).inspect}\n"
        message += "actual collection contained: #{safe_sort(@actual).inspect}\n"
        message += "the missing elements were: #{safe_sort(@missing_items).inspect}\n" unless @missing_items.empty?
        message += "the extra elements were: #{safe_sort(@extra_items).inspect}\n" unless @extra_items.empty?
      else
        message = "expected an array, actual collection was #{@actual.inspect}"
      end

      message
    end

    private

    def safe_sort(array)
      array.sort rescue array
    end

    def difference_between_enumerators(array_1, array_2)
      difference = array_1.to_a.dup
      array_2.to_a.each do |element|
        if (index = difference.index(element))
          difference.delete_at(index)
        end
      end
      difference
    end
  end # MatchEnumerator

  def assert_match_enumerator(expected, actual)
    result, message = MatchEnumerator.new(expected, actual).match
    assert result, message
  end
end # MiniTest::Assertions

Enumerator.infect_an_assertion :assert_match_enumerator, :must_contain_exactly
