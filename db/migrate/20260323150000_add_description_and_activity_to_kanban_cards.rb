class AddDescriptionAndActivityToKanbanCards < ActiveRecord::Migration[8.1]
  class MigrationKanbanCard < ApplicationRecord
    self.table_name = 'kanban_cards'
  end

  def up
    add_column :kanban_cards, :description, :text
    add_column :kanban_cards, :review_focus, :text
    add_column :kanban_cards, :activity_entries, :jsonb, default: [], null: false

    MigrationKanbanCard.reset_column_information

    say_with_time 'Backfilling description/activity/review focus from legacy fields' do
      MigrationKanbanCard.find_each do |card|
        activity_entries = []

        if card[:notes].present?
          activity_entries << {
            'body' => card[:notes],
            'created_at' => (card[:updated_at] || card[:created_at] || Time.current).utc.iso8601,
            'kind' => 'update',
            'source' => 'legacy_notes'
          }
        end

        if card[:review_notes].present?
          activity_entries << {
            'body' => card[:review_notes],
            'created_at' => (card[:completed_at] || card[:updated_at] || card[:created_at] || Time.current).utc.iso8601,
            'kind' => 'review',
            'source' => 'legacy_review_notes'
          }
        end

        card.update_columns(
          description: card[:summary],
          review_focus: card[:review_notes],
          activity_entries: activity_entries.sort_by { |entry| entry['created_at'].to_s }.reverse
        )
      end
    end
  end

  def down
    remove_column :kanban_cards, :activity_entries
    remove_column :kanban_cards, :review_focus
    remove_column :kanban_cards, :description
  end
end
