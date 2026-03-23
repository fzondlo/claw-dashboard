class KanbanCard < ApplicationRecord
  STATUSES = %w[queued in_progress ready_for_review complete icebox].freeze
  NO_PROJECT = "No project".freeze
  QA_URL_REGEX = %r{https?://[^\s<>"']+}i.freeze
  BOARD_EXCLUDED_TAGS = %w[smoke test testing qa-only internal-only hidden].freeze

  attr_accessor :archive_requested

  belongs_to :project, optional: true

  before_validation :ensure_task_number, on: :create
  before_validation :normalize_work_state
  validate :prevent_unrequested_archive, on: :update
  validate :single_active_in_progress_per_lane, if: :enforcing_in_progress_lane_uniqueness?
  validate :ready_for_review_requires_qa_link, if: :ready_for_review?

  validates :title, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :task_number, presence: true, uniqueness: true

  scope :manual_board, -> { where(active: true).where.not(status: :in_progress) }
  scope :ordered, -> { order(Arel.sql("COALESCE(sort_order, 999999), created_at ASC")) }
  scope :timed_out, -> { where.not(timed_out_at: nil) }
  scope :board_visible, lambda {
    where(active: true)
      .where("COALESCE(metadata ->> 'board_hidden', 'false') != 'true'")
      .where("NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(tags, '[]'::jsonb)) tag WHERE LOWER(tag) IN (?))", BOARD_EXCLUDED_TAGS)
  }

  def timed_out?
    timed_out_at.present?
  end

  def effective_requeue_recommendation
    requeue_recommendation.to_s.strip.presence || timeout_recommendation.to_s.strip
  end

  def ready_for_review?
    status == 'ready_for_review'
  end

  def qa_urls
    review_context_text.scan(QA_URL_REGEX).uniq
  end

  def qa_ready?
    qa_urls.any?
  end

  def board_hidden?
    metadata_value('board_hidden') || tag_list.any? { |tag| BOARD_EXCLUDED_TAGS.include?(tag.to_s.downcase) }
  end

  def claim_for_worker!(worker:, lane:, occurred_at: Time.current, metadata: {})
    worker_name = worker.to_s.strip
    lane_name = lane.to_s.strip
    raise ArgumentError, 'worker is required' if worker_name.blank?
    raise ArgumentError, 'lane is required' if lane_name.blank?

    with_lock do
      raise "card ##{id} is not queued" unless status == 'queued'
      ensure_lane_available!(lane_name)

      merged_metadata = (self.metadata || {}).deep_dup
      merged_metadata['dispatcher'] = (merged_metadata['dispatcher'] || {}).merge(
        metadata.deep_stringify_keys,
        'claimedAt' => occurred_at.iso8601,
        'worker' => worker_name,
        'lane' => lane_name
      )

      update!(
        status: 'in_progress',
        worker: worker_name,
        lane: lane_name,
        active: true,
        completed_at: nil,
        timed_out_at: nil,
        timeout_recommendation: nil,
        requeue_recommendation: nil,
        timeout_metadata: {},
        in_progress_since: occurred_at,
        metadata: merged_metadata
      )
    end
  end

  def complete_work!(review_notes:, worker: nil, lane: nil, occurred_at: Time.current, activity_body: nil, activity_source: 'kanban_card_update')
    normalized_review_notes = review_notes.to_s.strip
    raise ArgumentError, 'review notes must include at least one QA URL' if normalized_review_notes.scan(QA_URL_REGEX).empty?

    with_lock do
      update!(
        status: 'ready_for_review',
        review_focus: normalized_review_notes,
        review_notes: normalized_review_notes,
        worker: worker.presence || self.worker,
        lane: lane.presence || self.lane,
        completed_at: occurred_at,
        in_progress_since: nil
      )
      append_activity!(
        body: activity_body.presence || normalized_review_notes,
        created_at: occurred_at,
        kind: 'review_ready',
        source: activity_source
      )
    end
  end

  def mark_timed_out!(timeout_recommendation: nil, requeue_recommendation: nil, review_focus: nil, metadata: {}, occurred_at: Time.current, activity_body: nil, activity_source: 'timeout')
    normalized_timeout_recommendation = timeout_recommendation.to_s.strip
    normalized_requeue_recommendation = requeue_recommendation.to_s.strip
    normalized_review_focus = review_focus.to_s.strip
    normalized_metadata = (self.timeout_metadata || {}).deep_dup
    normalized_metadata.merge!(metadata.deep_stringify_keys) if metadata.present?

    update!(
      status: 'ready_for_review',
      timed_out_at: occurred_at,
      timeout_recommendation: normalized_timeout_recommendation.presence,
      requeue_recommendation: normalized_requeue_recommendation.presence || normalized_timeout_recommendation.presence,
      review_focus: normalized_review_focus.presence || self.review_focus,
      timeout_metadata: normalized_metadata,
      completed_at: occurred_at,
      in_progress_since: nil
    )

    append_activity!(
      body: activity_body.presence || default_timeout_activity_body(normalized_timeout_recommendation, normalized_requeue_recommendation, normalized_review_focus),
      created_at: occurred_at,
      kind: 'timeout',
      source: activity_source
    )
  end

  def requeue_with_recommendation!(occurred_at: Time.current, source: 'kanban_board')
    recommendation = effective_requeue_recommendation
    raise 'Only timed-out review tasks can be requeued with recommendation.' unless ready_for_review? && recommendation.present?

    with_lock do
      notes_parts = [notes.presence, "Retry recommendation:\n#{recommendation}"].compact
      update!(
        status: 'queued',
        worker: nil,
        lane: nil,
        in_progress_since: nil,
        completed_at: nil,
        notes: notes_parts.join("\n\n"),
        requeue_recommendation: nil,
        timeout_recommendation: nil,
        timeout_metadata: {}
      )
      append_activity!(body: "Requeued with timeout recommendation.\n\n#{recommendation}", created_at: occurred_at, kind: 'requeue', source: source)
    end
  end

  def self.archive_scope!(scope)
    count = 0

    transaction do
      scope.find_each do |card|
        card.archive!
        count += 1
      end
    end

    count
  end

  def archive!
    self.archive_requested = true
    update!(active: false)
  ensure
    self.archive_requested = false
  end

  def tag_list
    Array(tags)
  end

  def project_name
    project&.name.presence || NO_PROJECT
  end

  def display_task_id
    task_number || id
  end

  def activity_entries_list
    Array(activity_entries).filter_map do |entry|
      next if entry.blank?

      normalized = entry.respond_to?(:deep_symbolize_keys) ? entry.deep_symbolize_keys : entry
      body = normalized[:body].to_s
      next if body.blank?

      {
        body: body,
        created_at: parse_activity_time(normalized[:created_at]),
        kind: normalized[:kind].presence || 'update',
        source: normalized[:source].presence
      }
    end.sort_by { |entry| entry[:created_at] || Time.at(0) }.reverse
  end

  def append_activity!(body:, created_at: Time.current, kind: 'update', source: nil)
    return if body.to_s.strip.blank?

    entries = activity_entries_list.map do |entry|
      {
        'body' => entry[:body],
        'created_at' => entry[:created_at]&.utc&.iso8601,
        'kind' => entry[:kind],
        'source' => entry[:source]
      }.compact
    end

    entries.unshift(
      {
        'body' => body.to_s,
        'created_at' => created_at.utc.iso8601,
        'kind' => kind,
        'source' => source
      }.compact
    )

    update!(activity_entries: entries)
  end

  private

  def prevent_unrequested_archive
    return unless will_save_change_to_active?
    return unless active_change_to_be_saved == [true, false]
    return if archive_requested

    errors.add(:active, 'can only be set false through an explicit archive action')
  end

  def normalize_work_state
    self.worker = worker.to_s.strip.presence
    self.lane = lane.to_s.strip.presence
    self.review_focus = review_focus.to_s.strip.presence
    self.review_notes = review_notes.to_s.strip.presence

    case status
    when 'queued', 'icebox'
      self.worker = nil
      self.lane = nil
      self.in_progress_since = nil
      self.completed_at = nil if status == 'queued'
    when 'in_progress'
      self.active = true if active.nil?
      self.in_progress_since ||= Time.current
      self.completed_at = nil
    when 'ready_for_review', 'complete'
      self.in_progress_since = nil
      self.completed_at ||= Time.current
    end
  end

  def enforcing_in_progress_lane_uniqueness?
    status == 'in_progress' && lane.present?
  end

  def single_active_in_progress_per_lane
    conflict = self.class.where(status: 'in_progress', active: true)
      .where('LOWER(lane) = ?', lane.to_s.downcase)
      .where.not(id: id)
      .exists?
    return unless conflict

    errors.add(:lane, 'already has an in-progress card assigned')
  end

  def ready_for_review_requires_qa_link
    return if timed_out?
    return if qa_ready?

    errors.add(:review_focus, 'must include at least one QA URL before moving to ready_for_review')
  end

  def review_context_text
    [review_notes, review_focus, description, notes, *activity_entries_list.map { |entry| entry[:body] }].compact.join("\n")
  end

  def metadata_value(key)
    value = (metadata || {})[key.to_s]
    value == true || value.to_s.casecmp('true').zero?
  end

  def ensure_lane_available!(lane_name)
    conflict = self.class.lock.where(status: 'in_progress', active: true)
      .where('LOWER(lane) = ?', lane_name.downcase)
      .where.not(id: id)
      .first
    raise "lane #{lane_name} already has card ##{conflict.id}" if conflict
  end

  def ensure_task_number
    return if task_number.present?

    used_numbers = self.class.where.not(task_number: nil).pluck(:task_number).sort
    next_number = 1
    used_numbers.each do |number|
      break if number > next_number
      next_number = number + 1 if number == next_number
    end
    self.task_number = next_number
  end

  def parse_activity_time(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def default_timeout_activity_body(timeout_recommendation, requeue_recommendation, review_focus)
    parts = ['Task timed out and moved to Ready for review.']
    parts << "Timeout recommendation:\n#{timeout_recommendation}" if timeout_recommendation.present?
    if requeue_recommendation.present? && requeue_recommendation != timeout_recommendation
      parts << "Requeue recommendation:\n#{requeue_recommendation}"
    end
    parts << "Review focus:\n#{review_focus}" if review_focus.present?
    parts.join("\n\n")
  end
end
