# frozen_string_literal: true

require 'view_model/utils/collections'

class ViewModel::Changes
  using ViewModel::Utils::Collections

  attr_reader :new, :changed_attributes, :changed_associations, :changed_nested_children, :changed_referenced_children, :deleted

  alias new? new
  alias deleted? deleted
  alias changed_nested_children? changed_nested_children
  alias changed_referenced_children? changed_referenced_children

  def initialize(new: false, changed_attributes: [], changed_associations: [], changed_nested_children: false, changed_referenced_children: false, deleted: false)
    @new                         = new
    @changed_attributes          = changed_attributes.map(&:to_s)
    @changed_associations        = changed_associations.map(&:to_s)
    @changed_nested_children     = changed_nested_children
    @changed_referenced_children = changed_referenced_children
    @deleted                     = deleted
  end

  def contained_to?(associations: [], attributes: [])
    !deleted? &&
      changed_associations.all? { |assoc| associations.include?(assoc.to_s) } &&
      changed_attributes.all? { |attr| attributes.include?(attr.to_s) }
  end

  def changed_any?(associations: [], attributes: [])
    associations.any? { |assoc| changed_associations.include?(assoc.to_s) } ||
      attributes.any? { |attr| changed_attributes.include?(attr.to_s) }
  end

  def changed?
    new? || deleted? || changed_attributes.present? || changed_associations.present?
  end

  def changed_nested_tree?
    changed? || changed_nested_children?
  end

  def changed_owned_tree?
    changed? || changed_nested_children? || changed_referenced_children?
  end

  def to_h
    {
      'changed_attributes'          => changed_attributes.dup,
      'changed_associations'        => changed_associations.dup,
      'new'                         => new?,
      'changed_nested_children'     => changed_nested_children?,
      'changed_referenced_children' => changed_referenced_children?,
      'deleted'                     => deleted?,
    }
  end

  def ==(other)
    return false unless other.is_a?(ViewModel::Changes)

    self.new? == other.new? &&
      self.changed_nested_children? == other.changed_nested_children? &&
      self.changed_referenced_children? == other.changed_referenced_children? &&
      self.deleted? == other.deleted? &&
      self.changed_attributes.contains_exactly?(other.changed_attributes) &&
      self.changed_associations.contains_exactly?(other.changed_associations)
  end

  alias eql? ==
end
