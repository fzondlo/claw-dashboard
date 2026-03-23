#!/usr/bin/env ruby
require_relative '../config/environment'
require 'json'
require 'optparse'

options = {
  activity: nil,
  review_focus: nil,
  timeout_recommendation: nil,
  requeue_recommendation: nil,
  timeout_metadata_json: nil,
  worker: nil,
  lane: nil,
  project: nil,
  description: nil,
  activity_kind: 'update'
}

parser = OptionParser.new do |opts|
  opts.on('--activity TEXT') { |v| options[:activity] = v }
  opts.on('--review-focus TEXT') { |v| options[:review_focus] = v }
  opts.on('--review-notes TEXT') { |v| options[:review_focus] = v }
  opts.on('--timeout-recommendation TEXT') { |v| options[:timeout_recommendation] = v }
  opts.on('--requeue-recommendation TEXT') { |v| options[:requeue_recommendation] = v }
  opts.on('--timeout-metadata-json JSON') { |v| options[:timeout_metadata_json] = v }
  opts.on('--worker TEXT') { |v| options[:worker] = v }
  opts.on('--lane TEXT') { |v| options[:lane] = v }
  opts.on('--project TEXT') { |v| options[:project] = v }
  opts.on('--description TEXT') { |v| options[:description] = v }
  opts.on('--activity-kind TEXT') { |v| options[:activity_kind] = v }
end
parser.parse!(ARGV)

id = Integer(ARGV.shift)
status = ARGV.shift.to_s
abort('usage: kanban_card_update.rb ID STATUS [--activity ...]') if id.nil? || status.empty?

card = KanbanCard.find(id)

case status
when 'ready_for_review'
  if options[:timeout_recommendation].present? || options[:requeue_recommendation].present? || options[:timeout_metadata_json].present?
    timeout_metadata = options[:timeout_metadata_json].present? ? JSON.parse(options[:timeout_metadata_json]) : {}
    card.mark_timed_out!(
      timeout_recommendation: options[:timeout_recommendation],
      requeue_recommendation: options[:requeue_recommendation],
      review_focus: options[:review_focus],
      metadata: timeout_metadata,
      activity_body: options[:activity],
      activity_source: 'kanban_card_update'
    )
  else
    card.complete_work!(
      review_notes: options[:review_focus],
      worker: options[:worker],
      lane: options[:lane],
      occurred_at: Time.current,
      activity_body: options[:activity],
      activity_source: 'kanban_card_update'
    )
    card.update!(description: options[:description]) if options[:description]
  end
when 'in_progress'
  worker = options[:worker].presence || card.worker
  lane = options[:lane].presence || card.lane || worker
  card.claim_for_worker!(worker: worker, lane: lane, occurred_at: Time.current)
  card.update!(description: options[:description]) if options[:description]
  if options[:activity]
    card.append_activity!(body: options[:activity], kind: options[:activity_kind], source: 'kanban_card_update')
  end
else
  attrs = { status: status }
  attrs[:active] = true if status == 'in_progress'
  attrs[:review_focus] = options[:review_focus] if options[:review_focus]
  attrs[:review_notes] = options[:review_focus] if options[:review_focus]
  attrs[:worker] = options[:worker] if options[:worker]
  attrs[:lane] = options[:lane] if options[:lane]
  attrs[:description] = options[:description] if options[:description]
  if options[:project]
    project = Project.find_by(name: options[:project]) || Project.find_by(slug: options[:project])
    attrs[:project] = project
  end
  card.update!(attrs)

  if options[:activity]
    card.append_activity!(body: options[:activity], kind: options[:activity_kind], source: 'kanban_card_update')
  end
end

card.reload
puts({ ok: true, id: card.id, status: card.status, worker: card.worker, lane: card.lane, qa_urls: card.qa_urls }.to_json)
