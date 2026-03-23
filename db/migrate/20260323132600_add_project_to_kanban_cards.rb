class AddProjectToKanbanCards < ActiveRecord::Migration[8.1]
  def change
    add_column :kanban_cards, :project, :string
    add_index :kanban_cards, :project
  end
end
