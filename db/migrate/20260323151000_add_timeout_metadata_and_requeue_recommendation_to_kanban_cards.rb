class AddTimeoutMetadataAndRequeueRecommendationToKanbanCards < ActiveRecord::Migration[8.1]
  def change
    add_column :kanban_cards, :timeout_metadata, :jsonb, default: {}, null: false
    add_column :kanban_cards, :requeue_recommendation, :text
  end
end
