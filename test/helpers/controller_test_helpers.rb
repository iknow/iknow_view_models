# frozen_string_literal: true

require 'iknow_view_models'
require 'view_model/active_record'
require 'view_model/active_record/controller'

require_relative '../helpers/arvm_test_utilities'
require_relative '../helpers/arvm_test_models'

require 'action_controller'

require 'acts_as_manual_list'

# models for ARVM controller test
module ControllerTestModels
  def before_all
    super

    build_viewmodel(:Label) do
      define_schema do |t|
        t.string :text
      end
      define_model do
        has_one :parent
        has_one :target
      end
      define_viewmodel do
        attributes :text
      end
    end

    build_viewmodel(:Category) do
      define_schema do |t|
        t.string :name
      end
      define_model do
        has_many :parents
      end
      define_viewmodel do
        root!
        attributes :name
      end
    end

    build_viewmodel(:PolyOne) do
      define_schema do |t|
        t.integer :number
      end
      define_model do
        has_one :parent, as: :poly
      end
      define_viewmodel do
        attributes :number
      end
    end

    build_viewmodel(:PolyTwo) do
      define_schema do |t|
        t.string :text
      end
      define_model do
        has_one :parent, as: :poly
      end
      define_viewmodel do
        attributes :text
      end
    end

    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string     :name
        t.references :label, foreign_key: true
        t.string     :poly_type
        t.integer    :poly_id
        t.references :category, foreign_key: true # shared reference
      end
      define_model do
        has_many   :children, dependent: :destroy, inverse_of: :parent
        belongs_to :label,    dependent: :destroy
        has_one    :target,   dependent: :destroy, inverse_of: :parent
        belongs_to :poly, polymorphic: true, dependent: :destroy, inverse_of: :parent
        belongs_to :category
      end
      define_viewmodel do
        root!
        self.schema_version = 2

        attributes   :name
        associations :label, :target
        association  :children
        association  :poly, viewmodels: [:PolyOne, :PolyTwo]
        association  :category, external: true

        migrates from: 1, to: 2 do
          up do |view, _refs|
            if view.has_key?('old_name')
              view['name'] = view.delete('old_name')
            end
          end

          down do |view, _refs|
            view['old_name'] = view.delete('name')
          end
        end
      end
    end

    build_viewmodel(:Child) do
      define_schema do |t|
        t.references :parent, null: false, foreign_key: true
        t.string     :name
        t.float      :position
      end
      # Add age column separately in order to define CHECK constraint (no way to
      # specify in activerecord schema.
      ActiveRecord::Base.connection.execute(<<-SQL)
        ALTER TABLE children ADD COLUMN age integer CHECK(age > 21)
      SQL
      define_model do
        belongs_to :parent, inverse_of: :children
        acts_as_manual_list scope: :parent
        validates :age, numericality: { less_than: 42 }, allow_nil: true
      end
      define_viewmodel do
        attributes :name, :age
        acts_as_list :position
      end
    end

    build_viewmodel(:Target) do
      define_schema do |t|
        t.string     :text
        t.references :parent, foreign_key: true
        t.references :label, foreign_key: true
      end
      define_model do
        belongs_to :parent, inverse_of: :target
        belongs_to :label, dependent: :destroy
      end
      define_viewmodel do
        attributes :text
        association :label
      end
    end
  end
end

## Dummy Rails Controllers
class DummyController
  attr_reader :params, :headers, :status

  def initialize(headers: {}, params: {})
    @params = ActionController::Parameters.new(params)
    @headers = ActionDispatch::Http::Headers.from_hash({}).merge!(headers)
    @status = 200
  end

  def invoke(method)
    self.public_send(method)
  rescue StandardError => ex
    handler = self.class.rescue_block(ex.class)
    case handler
    when nil
      raise
    when Symbol
      self.send(handler, ex)
    when Proc
      self.instance_exec(ex, &handler)
    end
  end

  def invoke_without_rescue(method)
    self.public_send(method)
  end

  def render(status:, **options)
    if options.has_key?(:json)
      @response_body = options[:json]
      @content_type = options[:content_type] || 'application/json'
    elsif options.has_key?(:plain)
      @response_body = options[:plain]
      @content_type = options[:content_type] || 'text/plain'
    end
    @status = status unless status.nil?
  end

  def json_response
    raise 'Not a JSON response' unless @content_type == 'application/json'

    @response_body
  end

  def hash_response
    JSON.parse(json_response)
  end

  # for request.params and request.headers
  def request
    self
  end

  class << self
    def inherited(subclass)
      subclass.initialize_rescue_blocks
      super
    end

    def initialize_rescue_blocks
      @rescue_blocks = {}
    end

    def rescue_from(type, with:)
      @rescue_blocks[type] = with
    end

    def rescue_block(type)
      @rescue_blocks.to_a.reverse.detect { |btype, _h| type <= btype }.try(&:last)
    end

    def etag(*); end
  end
end

# Provide dummy Rails env
module RailsDummyEnv
  def env
    'production'
  end
end

module Rails; end
Rails.singleton_class.prepend(RailsDummyEnv)

module ActionController
  class Parameters
  end
end

module CallbackTracing
  attr_reader :callback_tracer

  delegate :hook_trace, to: :callback_tracer

  def new_deserialize_context(**_args)
    @callback_tracer ||= CallbackTracer.new
    super(callbacks: [@callback_tracer])
  end

  def new_serialize_context(**_args)
    @callback_tracer ||= CallbackTracer.new
    super(callbacks: [@callback_tracer])
  end
end

module ControllerTestControllers
  def before_all
    super

    Class.new(DummyController) do |_c|
      Object.const_set(:ParentController, self)
      include ViewModel::ActiveRecord::Controller
      include CallbackTracing
      self.access_control = ViewModel::AccessControl::Open
    end

    Class.new(DummyController) do |_c|
      Object.const_set(:ChildController, self)
      include ViewModel::ActiveRecord::Controller
      include CallbackTracing
      self.access_control = ViewModel::AccessControl::Open
      nested_in :parent, as: :children
    end

    Class.new(DummyController) do |_c|
      Object.const_set(:LabelController, self)
      include ViewModel::ActiveRecord::Controller
      include CallbackTracing
      self.access_control = ViewModel::AccessControl::Open
      nested_in :parent, as: :label
    end

    Class.new(DummyController) do |_c|
      Object.const_set(:TargetController, self)
      include ViewModel::ActiveRecord::Controller
      include CallbackTracing
      self.access_control = ViewModel::AccessControl::Open
      nested_in :parent, as: :target
    end
  end

  def after_all
    [:ParentController, :ChildController, :LabelController, :TargetController].each do |name|
      Object.send(:remove_const, name)
    end
    ActiveSupport::Dependencies::Reference.clear!
    super
  end
end
