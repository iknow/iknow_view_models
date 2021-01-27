# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'

require 'view_model'
require 'view_model/garbage_collection'

class ViewModel::GarbageCollectionTest < ActiveSupport::TestCase
  extend Minitest::Spec::DSL

  # Generate a viewmodel-serialization alike from a minimal structure
  # @param [Hash<Symbol, Array<Symbol>] structure mapping from id to referenced ids
  # @param [Hash<Symbol, Array<Symbol>] data_ids list of ids of data elements
  def mock_serialization(data_skeleton, refs_skeleton)
    data       = []
    references = {}

    generate(data_skeleton) do |id, body|
      data << body
    end

    generate(refs_skeleton) do |id, body|
      references[id] = body
    end

    {
      "data"       => data,
      "references" => references,
    }
  end

  def generate(skeleton)
    skeleton.each do |id, referred|
      yield id, ({
        ViewModel::ID_ATTRIBUTE => id,
        :children               => referred.map do |referred_id|
          { ViewModel::REFERENCE_ATTRIBUTE => referred_id }
        end
      })
    end
  end

  def retained_ids(data_skeleton, refs_skeleton)
    serialization = mock_serialization(data_skeleton, refs_skeleton)
    ViewModel::GarbageCollection.garbage_collect_references!(serialization)
    Set.new(
      (serialization['data'].map { |x| x[ViewModel::ID_ATTRIBUTE] }) +
        (serialization['references'].keys),
    )
  end

  it 'keeps all roots' do
    assert_equal(
      Set.new([:a, :b, :c]),
      retained_ids({ a: [], b: [], c: [] }, {})
    )
  end

  it 'keeps a list' do
    assert_equal(
      Set.new([:a, :b, :c, :d]),
      retained_ids({ a: [:b], }, { b: [:c], c: [:d], d: [] }),
    )
  end

  it 'keeps a child with a removed reference' do
    assert_equal(
      Set.new([:a, :z]),
      retained_ids({ a: [:z], }, { b: [:z], z: [] }),
    )
  end

  it 'prunes a list at the head' do
    assert_equal(
      Set.new([:a]),
      retained_ids({ a: [], }, { b: [:c], c: [:d], d: [] }),
    )
  end
end
