# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_23_151000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "kanban_cards", force: :cascade do |t|
    t.boolean "active"
    t.jsonb "activity_entries", default: [], null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "external_id"
    t.datetime "in_progress_since"
    t.string "lane"
    t.jsonb "metadata"
    t.text "notes"
    t.string "priority"
    t.string "project"
    t.bigint "project_id"
    t.text "requeue_recommendation"
    t.text "review_focus"
    t.text "review_notes"
    t.integer "sort_order"
    t.string "status"
    t.text "summary"
    t.jsonb "tags"
    t.integer "task_number"
    t.datetime "timed_out_at"
    t.jsonb "timeout_metadata", default: {}, null: false
    t.text "timeout_recommendation"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "worker"
    t.index ["external_id"], name: "index_kanban_cards_on_external_id", unique: true
    t.index ["project"], name: "index_kanban_cards_on_project"
    t.index ["project_id"], name: "index_kanban_cards_on_project_id"
    t.index ["status", "sort_order"], name: "index_kanban_cards_on_status_and_sort_order"
    t.index ["status"], name: "index_kanban_cards_on_status"
    t.index ["task_number"], name: "index_kanban_cards_on_task_number", unique: true
    t.index ["timed_out_at"], name: "index_kanban_cards_on_timed_out_at"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "link_label"
    t.string "name", null: false
    t.string "repo"
    t.string "slug", null: false
    t.string "status", default: "Active", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["name"], name: "index_projects_on_name", unique: true
    t.index ["slug"], name: "index_projects_on_slug", unique: true
  end

  add_foreign_key "kanban_cards", "projects"
end
