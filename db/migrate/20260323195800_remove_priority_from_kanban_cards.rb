class RemovePriorityFromKanbanCards < ActiveRecord::Migration[8.1]
  def change
    remove_column :kanban_cards, :priority, :string
  end
end
