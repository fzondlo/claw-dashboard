require 'ostruct'
require 'set'

class KanbanBoardController < ApplicationController
  COLUMN_ORDER = %w[icebox queued in_progress ready_for_review complete].freeze

  before_action :load_board!, only: %i[index board preview_v2 board_v2]

  def index
    @workers = lane_keys.map do |lane_key|
      heartbeat_path = Rails.root.join('..', 'memory', lane_key, 'HEARTBEAT.md')
      task = parse_heartbeat_task(heartbeat_path)
      {
        name: lane_key.sub('pixi', 'Pixi '),
        active: task.present?,
        task: task
      }
    end
  end

  def board
    render partial: 'board'
  end

  def preview_v2
  end

  def board_v2
    render partial: 'board_v2'
  end

  def destroy
    card = KanbanCard.find(params[:id])

    if card.active == false
      return render json: { error: 'Task is already archived.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Task is already archived.'
      return
    end

    card.archive!

    if request.xhr? || request.format.json?
      render json: { ok: true, archivedId: card.id, preservedStatus: card.status }
    else
      redirect_to kanban_path, notice: 'Task archived.'
    end
  end

  def archive_complete
    @selected_project = params[:project_id].to_s.presence
    scope = apply_project_filter(KanbanCard.board_visible.where(status: 'complete'))
    archived_count = KanbanCard.archive_scope!(scope)

    if request.xhr? || request.format.json?
      render json: { ok: true, archivedCount: archived_count }
    else
      redirect_to kanban_path(project_id: @selected_project.presence), notice: "Archived #{archived_count} completed #{'task'.pluralize(archived_count)}."
    end
  end

  def mark_complete
    card = KanbanCard.find(params[:id])

    if card.active == false
      return render json: { error: 'Task is already archived.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Task is already archived.'
      return
    end

    unless card.status == 'ready_for_review'
      return render json: { error: 'Only Ready for review tasks can be marked complete.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Only Ready for review tasks can be marked complete.'
      return
    end

    card.update!(status: 'complete', completed_at: Time.current)

    if request.xhr? || request.format.json?
      render json: { ok: true, completedId: card.id, status: card.status }
    else
      redirect_to kanban_path, notice: 'Task moved to Complete.'
    end
  end

  def requeue_with_recommendation
    card = KanbanCard.find(params[:id])

    if card.active == false
      return render json: { error: 'Task is already archived.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Task is already archived.'
      return
    end

    recommendation = card.effective_requeue_recommendation

    unless card.status == 'ready_for_review' && recommendation.present?
      return render json: { error: 'Only timed-out review tasks can be requeued with recommendation.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Only timed-out review tasks can be requeued with recommendation.'
      return
    end

    card.with_lock do
      card.requeue_with_recommendation!(source: 'kanban_board')
    end

    if request.xhr? || request.format.json?
      render json: { ok: true, requeuedId: card.id, status: card.status }
    else
      redirect_to kanban_path, notice: 'Task requeued with recommendation.'
    end
  end

  private

  def load_board!
    @updated_at = Time.current
    @selected_project = params[:project_id].to_s.presence
    @project_options = Project.ordered.to_a

    @columns = {
      'icebox' => filtered_manual_cards('icebox'),
      'queued' => filtered_manual_cards('queued'),
      'in_progress' => merged_in_progress_cards,
      'ready_for_review' => filtered_manual_cards('ready_for_review'),
      'complete' => filtered_manual_cards('complete')
    }
    @board_updated_at = board_updated_at
  end

  def filtered_manual_cards(status)
    scope = KanbanCard.board_visible.where(status: status)
    scope = apply_project_filter(scope)
    scope.ordered
  end

  def merged_in_progress_cards
    live_cards = filtered_live_in_progress_cards
    occupied_lanes = live_cards.map { |card| card.lane.to_s.downcase }.to_set
    manual_cards = filtered_manual_cards('in_progress').reject do |card|
      occupied_lanes.include?(card.lane.to_s.downcase)
    end
    manual_cards + live_cards
  end

  def filtered_live_in_progress_cards
    live_in_progress_cards.select { |card| project_match?(card.project_id) }
  end

  def live_in_progress_cards
    lane_keys.filter_map do |lane_key|
      heartbeat_path = Rails.root.join('..', 'memory', lane_key, 'HEARTBEAT.md')
      task = parse_heartbeat_task(heartbeat_path)
      next unless task

      manual_card = active_manual_card_for_lane(lane_key)
      project = manual_card&.project || infer_project(task, lane_key)
      lane_label = lane_key.sub('pixi', 'Pixi ')
      heartbeat_updated_at = File.mtime(heartbeat_path) rescue nil

      activity_entries = manual_card&.activity_entries_list || []
      activity_entries = [
        {
          body: "Live worker task derived from HEARTBEAT.md\n\n#{task}",
          created_at: Time.current,
          kind: 'heartbeat',
          source: 'heartbeat'
        }
      ] if activity_entries.empty?

      OpenStruct.new(
        id: manual_card&.id,
        task_number: manual_card&.task_number,
        external_id: manual_card&.external_id,
        title: manual_card&.title.presence || task,
        project: project,
        lane: manual_card&.lane.presence || lane_label,
        worker: manual_card&.worker.presence || lane_label,
        priority: manual_card&.priority.presence || 'Normal',
        description: manual_card&.description.presence || task,
        status: 'in_progress',
        tags: manual_card&.tag_list || [],
        activity_entries_list: activity_entries,
        review_focus: manual_card&.review_focus,
        project_name: project&.name.presence || KanbanCard::NO_PROJECT,
        project_id: project&.id,
        display_task_id: manual_card&.display_task_id || lane_label,
        in_progress_since: manual_card&.in_progress_since || heartbeat_updated_at,
        updated_at: manual_card&.updated_at || heartbeat_updated_at
      )
    end
  end

  def lane_keys
    %w[pixi1 pixi2 pixi3 pixi4 pixi5 pixi6 pixi7 pixi8]
  end

  def apply_project_filter(scope)
    return scope if @selected_project.blank?
    return scope.where(project_id: nil) if @selected_project == 'none'

    scope.where(project_id: @selected_project)
  end

  def project_match?(project_id)
    return true if @selected_project.blank?
    return project_id.nil? if @selected_project == 'none'

    project_id.to_s == @selected_project
  end

  def infer_project(task, lane_key)
    text = task.downcase
    project_name = if text.include?('raizia') || text.include?('laureles') || text.include?('property')
      'Raizia'
    elsif text.include?('dash') || text.include?('kanban')
      'Dashboard'
    elsif text.include?('openclaw') || text.include?('session') || text.include?('runtime')
      'OpenClaw'
    else
      nil
    end

    project_name.present? ? Project.find_by(name: project_name) : nil
  end

  def active_manual_card_for_lane(lane_key)
    lane_label = lane_key.sub('pixi', 'Pixi ')
    candidates = [lane_key.downcase, lane_label.downcase].uniq

    KanbanCard.where(status: 'in_progress', active: true)
      .where('LOWER(lane) IN (?) OR LOWER(worker) IN (?)', candidates, candidates)
      .order(updated_at: :desc)
      .first
  end

  def parse_heartbeat_task(path)
    text = File.read(path)
    match = text.match(/Active task:\s*(.+)/i)
    return unless match

    task = match[1].to_s.gsub(/[*_`~]/, '').strip
    return if task.blank? || task == '(none)' || task.casecmp('none').zero?

    task
  rescue Errno::ENOENT
    nil
  end

  def board_updated_at
    timestamps = []
    latest_card_update = KanbanCard.maximum(:updated_at)
    timestamps << latest_card_update if latest_card_update.present?

    lane_keys.each do |lane_key|
      heartbeat_path = Rails.root.join('..', 'memory', lane_key, 'HEARTBEAT.md')
      timestamps << File.mtime(heartbeat_path)
    rescue Errno::ENOENT
      next
    end

    timestamps.max || Time.current
  end
end
