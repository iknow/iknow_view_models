require "view_model/utils/collections"
class ViewModel::Changes
  using ViewModel::Utils::Collections

  attr_reader :new, :changed_attributes, :changed_associations, :deleted

  alias new? new
  alias deleted? deleted

  def initialize(new: false, changed_attributes: [], changed_associations: [], deleted: false)
    @new                  = new
    @changed_attributes   = changed_attributes.map(&:to_s)
    @changed_associations = changed_associations.map(&:to_s)
    @deleted              = deleted
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

  def ==(other)
    return false unless other.is_a?(ViewModel::Changes)

    self.new? == other.new? &&
      self.changed_attributes.contains_exactly?(other.changed_attributes) &&
      self.changed_associations.contains_exactly?(other.changed_associations) &&
      self.deleted? == other.deleted?
  end

  alias eql? ==
end
