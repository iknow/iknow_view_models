require 'active_record_view_model/controller_base'

module ActiveRecordViewModel::AssociationController
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
  end

  # List items associated with the target
  def index

  end

  # Deserialize items of the associated type and associate them with the target.
  # For a multiple association, can provide a single item to append to the
  # collection or an array of items to replace the collection.
  def create

  end

  # Remove the association between the target and the provided item, garbage
  # collecting the item if specified as `dependent:` by the association.
  def destroy
  end
end
