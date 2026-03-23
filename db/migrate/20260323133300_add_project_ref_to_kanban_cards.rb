class AddProjectRefToKanbanCards < ActiveRecord::Migration[8.1]
  def change
    add_reference :kanban_cards, :project, foreign_key: true
  end
end
