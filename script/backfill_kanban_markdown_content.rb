#!/usr/bin/env ruby
require_relative '../config/environment'
require_relative '../app/helpers/kanban_board_helper'

helper = Object.new.extend(KanbanBoardHelper)
updated = 0

KanbanCard.find_each do |card|
  changes = {}

  description = helper.send(:normalize_markdownish_content, card.description)
  review_focus = helper.send(:normalize_markdownish_content, card.review_focus)
  activity_entries = card.activity_entries_list.map do |entry|
    normalized_body = helper.send(:normalize_markdownish_content, entry[:body])
    {
      'body' => normalized_body,
      'created_at' => entry[:created_at]&.utc&.iso8601,
      'kind' => entry[:kind],
      'source' => entry[:source]
    }.compact
  end

  changes[:description] = description if description != card.description.to_s
  changes[:review_focus] = review_focus if review_focus != card.review_focus.to_s
  changes[:review_notes] = review_focus if card.review_notes.to_s == card.review_focus.to_s && review_focus != card.review_notes.to_s
  changes[:activity_entries] = activity_entries if activity_entries != Array(card.activity_entries)

  next if changes.empty?

  card.update_columns(changes.merge(updated_at: Time.current))
  updated += 1
end

puts({ ok: true, updated: updated }.to_json)
