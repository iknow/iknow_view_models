# frozen_string_literal: true

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

    def viewmodel_base
      ViewModelBase
    end

    def model_base
      ApplicationRecord
    end

    def model_class
      viewmodel_class.model_class
    end

    def child_model_class
      child_viewmodel_class.model_class
    end

    def view_name
      viewmodel_class.view_name
    end

    def child_view_name
      child_viewmodel_class.view_name
    end

    def viewmodel_class
      @viewmodel_class ||= define_viewmodel_class(
        :Model,
        spec:           model_attributes,
        namespace:      namespace,
        viewmodel_base: viewmodel_base,
        model_base:     model_base).tap { |klass| yield(klass) if block_given? }
    end

    def child_viewmodel_class
      @child_viewmodel_class ||= define_viewmodel_class(
        :Child,
        spec:           child_attributes,
        namespace:      namespace,
        viewmodel_base: viewmodel_base,
        model_base:     model_base).tap { |klass| yield(klass) if block_given? }
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
        viewmodel: ->(_v) { root!; attribute :name },
      )
    end

    def child_attributes
      ViewModel::TestHelpers::ARVMBuilder::Spec.new(
        schema:    ->(t) { t.string :name },
        model:     ->(m) {},
        viewmodel: ->(_v) { attribute :name },
      )
    end

    def define_viewmodel_class(name, **args, &block)
      builder = ViewModel::TestHelpers::ARVMBuilder.new(name, **args, &block)
      @builders << builder
      builder.viewmodel
    end

    def subject_association
      raise RuntimeError.new('Test model does not have a child association')
    end

    def subject_association_features
      {}
    end

    def subject_association_name
      subject_association.association_name
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
      f = subject_association_features
      super.merge(schema:    ->(t) { t.references :child, foreign_key: true },
                  model:     ->(_m) { belongs_to :child, inverse_of: :model, dependent: :destroy },
                  viewmodel: ->(_v) { association :child, **f })
    end

    def child_attributes
      super.merge(model: ->(_m) { has_one :model, inverse_of: :child })
    end

    # parent depends on child, ensure it's touched first
    def viewmodel_class
      child_viewmodel_class
      super
    end

    def subject_association
      viewmodel_class._association_data('child')
    end
  end

  module ParentAndChildMigrations
    extend ActiveSupport::Concern

    def model_attributes
      super.merge(
        schema: ->(t) { t.integer :new_field, default: 1, null: false },
        viewmodel: ->(_v) {
          self.schema_version = 4

          attribute :new_field

          # add: old_field (one-way)
          migrates from: 1, to: 2 do
            down do |view, _refs|
              view.delete('old_field')
            end
          end

          # rename: old_field -> mid_field
          migrates from: 2, to: 3 do
            up do |view, _refs|
              if view.has_key?('old_field')
                view['mid_field'] = view.delete('old_field') + 1
              end
            end

            down do |view, _refs|
              view['old_field'] = view.delete('mid_field') - 1
            end
          end

          # rename: mid_field -> new_field
          migrates from: 3, to: 4 do
            up do |view, _refs|
              if view.has_key?('mid_field')
                view['new_field'] = view.delete('mid_field') + 1
              end
            end

            down do |view, _refs|
              view['mid_field'] = view.delete('new_field') - 1
            end
          end
        })
    end

    def child_attributes
      super.merge(
        viewmodel: ->(_v) {
          self.schema_version = 3

          # delete: former_field
          migrates from: 2, to: 3 do
            up do |view, _refs|
              view.delete('former_field')
            end

            down do |view, _refs|
              view['former_field'] = 'reconstructed'
            end
          end
        })
    end
  end

  module SingleWithInheritedMigration
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def migration_bearing_viewmodel_class
      define_viewmodel_class(
        :MigrationBearingView,
        namespace: namespace,
        viewmodel_base: viewmodel_base,
        model_base: model_base,
        spec: ViewModel::TestHelpers::ARVMBuilder::Spec.new(
          schema: ->(_) {},
          model: ->(_) {},
          viewmodel: ->(v) {
            root!
            self.schema_version = 2
            migrates from: 1, to: 2 do
              down do |view, _refs|
                view['inherited_base'] = 'present'
              end
            end
          }))
    end

    def model_attributes
      migration_bearing_viewmodel_class = self.migration_bearing_viewmodel_class

      super.merge(
        schema: ->(t) { t.integer :new_field, default: 1, null: false },
        viewmodel: ->(_v) {
          self.schema_version = 2

          attribute :new_field

          migrates from: 1, to: 2, inherit: migration_bearing_viewmodel_class, at: 2 do
            down do |view, refs|
              super(view, refs)
              view.delete('new_field')
            end

            up do |view, refs|
              view.delete('inherited_base')
              view['new_field'] = 100
            end
          end
        })
    end
  end

  module ParentAndBelongsToChildWithMigration
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::ParentAndBelongsToChild
    include ViewModelSpecHelpers::ParentAndChildMigrations
  end

  module ParentAndSharedBelongsToChild
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::ParentAndBelongsToChild
    def child_attributes
      super.merge(viewmodel: ->(_v) { root! })
    end
  end

  module List
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      ViewModel::TestHelpers::ARVMBuilder::Spec.new(
        schema:    ->(t) {
          t.string :name
          t.integer :next_id
        },
        model:     ->(_m) {
          belongs_to :next, class_name: self.name, inverse_of: :previous, dependent: :destroy
          has_one :previous, class_name: self.name, foreign_key: :next_id, inverse_of: :next
        },
        viewmodel: ->(_v) {
          # Not a root
          association :next
          attribute :name
        })
    end

    def subject_association
      viewmodel_class._association_data('next')
    end
  end

  module ParentAndHasOneChild
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      f = subject_association_features
      super.merge(
        model:     ->(_m) { has_one :child, inverse_of: :model, dependent: :destroy },
        viewmodel: ->(_v) { association :child, **f },
      )
    end

    def child_attributes
      super.merge(
        schema: ->(t) { t.references :model, foreign_key: true },
        model:  ->(_m) { belongs_to :model, inverse_of: :child },
      )
    end

    # child depends on parent, ensure it's touched first
    def child_viewmodel_class
      viewmodel_class
      super
    end

    def subject_association
      viewmodel_class._association_data('child')
    end
  end

  module ParentAndReferencedHasOneChild
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::ParentAndHasOneChild
    def child_attributes
      super.merge(viewmodel: ->(_v) { root! })
    end
  end

  module ParentAndHasManyChildren
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      f = subject_association_features
      super.merge(
        model:     ->(_m) { has_many :children, inverse_of: :model, dependent: :destroy },
        viewmodel: ->(_v) { association :children, **f },
      )
    end

    def child_attributes
      super.merge(
        schema: ->(t) { t.references :model, foreign_key: true },
        model:  ->(_m) { belongs_to :model, inverse_of: :children },
      )
    end

    # child depends on parent, ensure it's touched first
    def child_viewmodel_class
      viewmodel_class
      super
    end

    def subject_association
      viewmodel_class._association_data('children')
    end
  end

  module ParentAndSharedHasManyChildren
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::ParentAndHasManyChildren
    def child_attributes
      super.merge(viewmodel: ->(_v) { root! })
    end
  end

  module ParentAndOrderedChildren
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::ParentAndHasManyChildren

    def child_attributes
      super.merge(
        schema:    ->(t) { t.float :position, null: false },
        model:     ->(_m) { acts_as_manual_list scope: :model },
        viewmodel: ->(_v) { acts_as_list :position },
      )
    end

    def child_viewmodel_class
      # child depends on parent, ensure it's touched first
      viewmodel_class

      # Add a deferrable unique position constraint
      super do |klass|
        model = klass.model_class
        table = model.table_name
        model.connection.execute <<-SQL
            ALTER TABLE #{table} ADD CONSTRAINT #{table}_unique_on_model_and_position UNIQUE(model_id, position) DEFERRABLE INITIALLY DEFERRED
        SQL
      end
    end
  end

  module ParentAndExternalSharedChild
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::ParentAndSharedBelongsToChild

    def subject_association_features
      { external: true }
    end
  end

  module ParentAndHasManyThroughChildren
    extend ActiveSupport::Concern
    include ViewModelSpecHelpers::Base

    def model_attributes
      f = subject_association_features
      super.merge(
        model:     ->(_m) { has_many :model_children, inverse_of: :model, dependent: :destroy },
        viewmodel: ->(_v) { association :children, through: :model_children, through_order_attr: :position, **f },
      )
    end

    def child_attributes
      super.merge(
        model: ->(_m) { has_many :model_children, inverse_of: :child, dependent: :destroy },
        viewmodel: ->(_v) { root! },
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

    def subject_association
      viewmodel_class._association_data('children')
    end
  end
end
