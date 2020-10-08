# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'
require 'minitest/hooks'

require_relative '../../helpers/arvm_test_utilities.rb'
require_relative '../../helpers/viewmodel_spec_helpers.rb'

require 'view_model'
require 'view_model/controller'

class ViewModel::ControllerTest < ActiveSupport::TestCase
  include ARVMTestUtilities
  extend Minitest::Spec::DSL

  describe 'rendering prerendered json terminals' do
    let(:controller) do
      Class.new do
        def self.rescue_from(*); end
        include ViewModel::Controller
        public :encode_jbuilder
      end
    end

    let(:terminal) { { 'a' => 100 } }

    let(:encoded_terminal) do
      ViewModel::Controller::CompiledJson.new(Oj.dump(terminal, mode: :compat))
    end

    let(:expected_dump) { encode(terminal) }
    let(:computed_dump) { encode(encoded_terminal) }

    def encode(value)
      controller.new.encode_jbuilder do |json|
        json.x value
      end
    end

    it 'passes through the prerendered data' do
      assert_equal(expected_dump, computed_dump)
    end
  end
end
