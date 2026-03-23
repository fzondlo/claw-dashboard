class AddTaskNumberToKanbanCards < ActiveRecord::Migration[8.1]
  class MigrationKanbanCard < ApplicationRecord
    self.table_name = 'kanban_cards'
  end

  def up
    add_column :kanban_cards, :task_number, :integer
    add_index :kanban_cards, :task_number, unique: true

    say_with_time 'Backfilling low task numbers for existing kanban cards' do
      MigrationKanbanCard.order(:created_at, :id).each_with_index do |card, index|
        card.update_columns(task_number: index + 1)
      end
    end
  end

  def down
    remove_index :kanban_cards, :task_number
    remove_column :kanban_cards, :task_number
  end
end
