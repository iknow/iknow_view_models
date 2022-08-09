# frozen_string_literal: true

class ViewModel::Migration
  require 'view_model/migration/no_path_error'
  require 'view_model/migration/one_way_error'
  require 'view_model/migration/unspecified_version_error'

  def up(view, _references)
    raise ViewModel::Migration::OneWayError.new(view[ViewModel::TYPE_ATTRIBUTE], :up)
  end

  def down(view, _references)
    raise ViewModel::Migration::OneWayError.new(view[ViewModel::TYPE_ATTRIBUTE], :down)
  end

  def self.renamed_from
    nil
  end

  def self.renamed?
    renamed_from.present?
  end

  delegate :renamed_from, :renamed?, to: :class

  # Tiny DSL for defining migration classes
  class Builder
    def initialize(superclass = ViewModel::Migration)
      @superclass = superclass
      @up_block = nil
      @down_block = nil
      @renamed_from = nil
    end

    def build!
      migration = Class.new(@superclass)
      migration.define_method(:up, &@up_block) if @up_block
      migration.define_method(:down, &@down_block) if @down_block

      # unconditionally define renamed_from: unlike up and down blocks, we do
      # not want to inherit previous view names.
      renamed_from = @renamed_from
      migration.define_singleton_method(:renamed_from) { renamed_from }
      migration
    end

    private

    def up(&block)
      check_signature!(block)
      @up_block = block
    end

    def down(&block)
      check_signature!(block)
      @down_block = block
    end

    def renamed_from(name)
      @renamed_from = name.to_s
    end

    def check_signature!(block)
      unless block.arity == 2
        raise RuntimeError.new('Illegal signature for migration method, must be (view, references)')
      end
    end
  end
end
