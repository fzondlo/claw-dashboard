class ArchivedTasksController < ApplicationController
  def index
    @updated_at = Time.current
    @archived_cards = KanbanCard.where(active: false).ordered
  end
end
