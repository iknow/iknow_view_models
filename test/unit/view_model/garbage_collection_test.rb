# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'

require 'view_model'
require 'view_model/garbage_collection'

class ViewModel::GarbageCollectionTest < ActiveSupport::TestCase
  extend Minitest::Spec::DSL

  # Generate a viewmodel-serialization alike from a minimal structure
  # @param [Hash<Symbol, Array<Symbol>] structure mapping from id to referenced ids
  # @param [Array<Symbol>] data_ids list of ids of data elements
  def mock_serialization(structure, data_ids)
    data_ids = data_ids.to_set

    data       = []
    references = {}

    structure.each do |id, referred|
      referred.each do |referred_id|
        if data_ids.include?(referred_id)
          raise "Invalid test: Element '#{id}' refers to '#{referred_id}', which is also in data"
        end
        references[referred_id] ||= {}
      end

      generated = {
        ViewModel::ID_ATTRIBUTE => id,
        :children               => referred.map do |referred_id|
          { ViewModel::REFERENCE_ATTRIBUTE => referred_id }
        end
      }

      if data_ids.include?(id)
        data << generated
      else
        references[id] = generated
      end
    end

    {
      "data"       => data,
      "references" => references,
    }
  end

  def retained_ids(structure, roots)
    serialization = mock_serialization(structure, roots)
    ViewModel::GarbageCollection.garbage_collect_references!(serialization)
    Set.new(
      (serialization['data'].map { |x| x[ViewModel::ID_ATTRIBUTE] }) +
        (serialization['references'].keys),
    )
  end

  it 'keeps all roots' do
    assert_equal(
      Set.new([:a, :b, :c]),
      retained_ids({ a: [], b: [], c: [] }, [:a, :b, :c])
    )
  end

  it 'keeps a list' do
    assert_equal(
      Set.new([:a, :b, :c, :d]),
      retained_ids({ a: [:b], b: [:c], c: [:d] }, [:a]),
    )
  end

  it 'keeps a child with a removed reference' do
    assert_equal(
      Set.new([:a, :z]),
      retained_ids({ a: [:z], b: [:z] }, [:a]),
    )
  end

  it 'prunes a list at the head' do
    assert_equal(
      Set.new([:a]),
      retained_ids({ a: [], b: [:c], c: [:d] }, [:a]),
    )
  end
end
