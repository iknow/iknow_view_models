require 'view_model'
require 'view_model/test_helpers'

require 'minitest/unit'
require 'minitest/hooks'

module ViewModelSpecHelpers
  module Base
    extend ActiveSupport::Concern
    include Minitest::Hooks # not a concern, can I do this?

    included do
      around do |&block|
        @builders = []
        super(&block)
        @builders.each do |b|
          b.teardown
        end
      end
    end

    def namespace
      Object
    end

    def model_class
      viewmodel_class.model_class
    end

    def child_model_class
      child_viewmodel_class.model_class
    end

    def viewmodel_class
      @viewmodel_class ||= define_viewmodel_class(:Model, spec: model_attributes, namespace: namespace)
    end

    def child_viewmodel_class
      @child_viewmodel_class ||= define_viewmodel_class(:Child, spec: child_attributes, namespace: namespace)
    end

    def create_viewmodel!
      viewmodel_class.new(create_model!)
    end

    def create_model!
      new_model.tap { |m| m.save! }
    end

    def model_attributes
      ViewModel::TestHelpers::ARVMBuilder::Spec.new(
        schema:    ->(t) { t.string :name },
        model:     ->(m) {},
        viewmodel: ->(v) { attribute :name }
      )
    end

    def child_attributes
      ViewModel::TestHelpers::ARVMBuilder::Spec.new(
        schema:    ->(t) { t.string :name },
        model:     ->(m) {},
        viewmodel: ->(v) { attribute :name }
      )
    end

    def define_viewmodel_class(name, **args, &block)
      builder = ViewModel::TestHelpers::ARVMBuilder.new(name, **args, &block)
      @builders << builder
      builder.viewmodel
    end
  end

  module Single
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base
  end

  module ParentAndBelongsToChild
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      super.merge(schema:    ->(t) { t.references :child, foreign_key: true },
                  model:     ->(m) { belongs_to :child, inverse_of: :model, dependent: :destroy },
                  viewmodel: ->(v) { association :child })
    end

    def child_attributes
      super.merge(model: ->(m) { has_one :model, inverse_of: :child })
    end

    # parent depends on child, ensure it's touched first
    def viewmodel_class
      child_viewmodel_class
      super
    end
  end

  module List
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      super.merge(schema:    ->(t) { t.integer :next_id },
                  model:     ->(m) {
                    belongs_to :next, class_name: self.name, inverse_of: :previous, dependent: :destroy
                    has_one :previous, class_name: self.name, foreign_key: :next_id, inverse_of: :next
                  },
                  viewmodel: ->(v) { association :next })
    end
  end

  module ParentAndHasOneChild
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      super.merge(
        model:     ->(m) { has_one :child, inverse_of: :model, dependent: :destroy },
        viewmodel: ->(v) { association :child }
      )
    end

    def child_attributes
      super.merge(
        schema: ->(t) { t.references :model, foreign_key: true },
        model:  ->(m) { belongs_to :model, inverse_of: :child }
      )
    end

    # child depends on parent, ensure it's touched first
    def child_viewmodel_class
      viewmodel_class
      super
    end
  end

  module ParentAndHasManyChildren
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      super.merge(
        model:     ->(m) { has_many :children, inverse_of: :model, dependent: :destroy },
        viewmodel: ->(v) { association :children }
      )
    end

    def child_attributes
      super.merge(
        schema: ->(t) { t.references :model, foreign_key: true },
        model:  ->(m) { belongs_to :model, inverse_of: :children }
      )
    end

    # child depends on parent, ensure it's touched first
    def child_viewmodel_class
      viewmodel_class
      super
    end
  end

  module ParentAndSharedChild
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      super.merge(
        schema:    ->(t) { t.references :child, foreign_key: true },
        model:     ->(m) { belongs_to :child, inverse_of: :model, dependent: :destroy },
        viewmodel: ->(v) { association :child, shared: true }
      )
    end

    def child_attributes
      super.merge(
        model: ->(m) { has_one :model, inverse_of: :child }
      )
    end

    # parent depends on child, ensure it's touched first
    def viewmodel_class
      child_viewmodel_class
      super
    end
  end

  module ParentAndHasManyThroughChildren
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      super.merge(
        model:     ->(m) { has_many :model_children, inverse_of: :model, dependent: :destroy },
        viewmodel: ->(v) { association :children, shared: true, through: :model_children, through_order_attr: :position }
      )
    end

    def child_attributes
      super.merge(
        model: ->(m) { has_many :model_children, inverse_of: :child, dependent: :destroy }
      )
    end

    def join_model_class
      # depends on parent and child
      viewmodel_class
      child_viewmodel_class

      @join_model_class ||=
        begin
          define_viewmodel_class(:ModelChild) do
            define_schema do |t|
              t.references :model, foreign_key: true
              t.references :child, foreign_key: true
              t.float      :position
            end

            define_model do
              belongs_to :model
              belongs_to :child
            end

            no_viewmodel
          end
          ModelChild
        end
    end
  end
end
