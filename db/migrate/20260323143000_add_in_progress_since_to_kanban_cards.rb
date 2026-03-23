class AddInProgressSinceToKanbanCards < ActiveRecord::Migration[8.1]
  def change
    add_column :kanban_cards, :in_progress_since, :datetime

    # Backfill: cards already in_progress get updated_at as a best estimate
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE kanban_cards
          SET in_progress_since = updated_at
          WHERE status = 'in_progress' AND in_progress_since IS NULL
        SQL
      end
    end
  end
end
