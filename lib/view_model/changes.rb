class ViewModel::Changes
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
end
