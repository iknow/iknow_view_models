# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'
require 'rspec/expectations/minitest_integration'

require 'view_model'
require 'view_model/deserialization_error'

class ViewModel::DeserializationError::UniqueViolationTest < ActiveSupport::TestCase
  extend Minitest::Spec::DSL

  # Test error parser
  describe 'message parser' do
    let(:parse) { ViewModel::DeserializationError::UniqueViolation.parse_message_detail(detail_message) }

    describe 'with a bad message prefix' do
      let(:detail_message) { 'Unexpected (x)=(y) already exists.' }

      it 'refuses to parse' do
        expect(parse).to be_nil
      end
    end

    describe 'with a bad message suffix' do
      let(:detail_message) { 'Key (x)=(y) is already present.' }

      it 'refuses to parse' do
        expect(parse).to be_nil
      end
    end

    describe 'with a single key and value' do
      let(:detail_message) { 'Key (x)=(a) already exists.' }

      it 'parses the key and value' do
        expect(parse).to eq([['x'], 'a', nil])
      end
    end

    describe 'with a exclusion conflict' do
      let(:detail_message) { 'Key (x)=(a) conflicts with existing key (x)=(z).' }

      it 'parses the key and value' do
        expect(parse).to eq([['x'], 'a', 'z'])
      end
    end

    describe 'with multiple keys and values' do
      let(:detail_message) { 'Key (x, y)=(a, b) already exists.' }

      it 'parses the keys and value' do
        expect(parse).to eq([['x', 'y'], 'a, b', nil])
      end
    end

    describe 'with quoted keys and values' do
      let(:detail_message) { 'Key ("x, y", z)=(a, b, c) already exists.' }

      it 'parses the keys and value' do
        expect(parse).to eq([['x, y', 'z'], 'a, b, c', nil])
      end
    end

    describe 'with nested quoted keys and values' do
      let(:detail_message) { 'Key ("""x"", ""y""", z)=(a, b, c) already exists.' }

      it 'parses the keys and value' do
        expect(parse).to eq([['"x", "y"', 'z'], 'a, b, c', nil])
      end
    end

    describe 'with unescaped values' do
      let(:detail_message) { 'Key (a, b)=(a, b)=(c, d) already exists.' }

      it 'parses the keys and value' do
        expect(parse).to eq([['a', 'b'], 'a, b)=(c, d', nil])
      end
    end
  end
end
