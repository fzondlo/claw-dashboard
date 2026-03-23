class CreateKanbanCards < ActiveRecord::Migration[8.1]
  def change
    create_table :kanban_cards do |t|
      t.string :title
      t.string :lane
      t.string :worker
      t.string :priority
      t.text :summary
      t.text :notes
      t.text :review_notes
      t.string :status
      t.jsonb :tags
      t.jsonb :metadata
      t.boolean :active
      t.datetime :completed_at
      t.integer :sort_order
      t.string :external_id

      t.timestamps
    end

    add_index :kanban_cards, :status
    add_index :kanban_cards, :external_id, unique: true
    add_index :kanban_cards, [:status, :sort_order]
  end
end
