class AddCompletionDurationSecondsToKanbanCards < ActiveRecord::Migration[8.1]
  def change
    add_column :kanban_cards, :completion_duration_seconds, :integer
  end
end
