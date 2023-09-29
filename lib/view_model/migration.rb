# frozen_string_literal: true

class ViewModel::Migration
  require 'view_model/migration/no_path_error'
  require 'view_model/migration/one_way_error'
  require 'view_model/migration/unspecified_version_error'

  REFERENCE_ONLY_KEYS = [
    ViewModel::TYPE_ATTRIBUTE,
    ViewModel::ID_ATTRIBUTE,
    ViewModel::VERSION_ATTRIBUTE,
  ].freeze

  def up(view, _references)
    # Only a reference-only view may be (trivially) migrated up without an
    # explicit migration.
    if (view.keys - REFERENCE_ONLY_KEYS).present?
      raise ViewModel::Migration::OneWayError.new(view[ViewModel::TYPE_ATTRIBUTE], :up)
    end
  end

  def down(view, _references)
    raise ViewModel::Migration::OneWayError.new(view[ViewModel::TYPE_ATTRIBUTE], :down)
  end

  # Tiny DSL for defining migration classes
  class Builder
    def initialize(superclass = ViewModel::Migration)
      @superclass = superclass
      @up_block = nil
      @down_block = nil
    end

    def build!
      migration = Class.new(@superclass)
      migration.define_method(:up, &@up_block) if @up_block
      migration.define_method(:down, &@down_block) if @down_block
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

    def check_signature!(block)
      unless block.arity == 2
        raise RuntimeError.new('Illegal signature for migration method, must be (view, references)')
      end
    end
  end
end
