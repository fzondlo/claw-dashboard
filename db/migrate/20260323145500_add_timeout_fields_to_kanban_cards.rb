class AddTimeoutFieldsToKanbanCards < ActiveRecord::Migration[8.0]
  def change
    add_column :kanban_cards, :timed_out_at, :datetime
    add_column :kanban_cards, :timeout_recommendation, :text

    add_index :kanban_cards, :timed_out_at
  end
end
