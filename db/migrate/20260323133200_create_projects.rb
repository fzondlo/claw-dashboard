class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :repo
      t.string :status, null: false, default: "Active"
      t.string :url
      t.string :link_label
      t.text :description

      t.timestamps
    end

    add_index :projects, :slug, unique: true
    add_index :projects, :name, unique: true
  end
end
