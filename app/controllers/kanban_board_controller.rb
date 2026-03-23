require 'ostruct'
require 'set'

class KanbanBoardController < ApplicationController
  COLUMN_ORDER = %w[icebox queued in_progress ready_for_review complete].freeze
  HEARTBEAT_STALE_AFTER = 5.minutes

  before_action :load_board!, only: %i[index create board preview_v2 board_v2]

  def index
  end

  def create
    @new_card = build_manual_card

    if @new_card.save
      if request.xhr? || request.format.json?
        render json: { ok: true, id: @new_card.id, status: @new_card.status }, status: :created
      else
        redirect_to kanban_path(project_id: @selected_project.presence), notice: "Task ##{@new_card.display_task_id} created."
      end
    else
      if request.xhr? || request.format.json?
        render json: { error: @new_card.errors.full_messages.to_sentence }, status: :unprocessable_entity
      else
        flash.now[:alert] = @new_card.errors.full_messages.to_sentence
        render :index, status: :unprocessable_entity
      end
    end
  end

  def board
    render partial: 'live_sections'
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

  def requeue_with_original_instructions
    card = KanbanCard.find(params[:id])

    if card.active == false
      return render json: { error: 'Task is already archived.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Task is already archived.'
      return
    end

    recommendation = card.effective_requeue_recommendation

    unless card.status == 'ready_for_review' && recommendation.present?
      return render json: { error: 'Only timed-out review tasks can be requeued with original instructions.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Only timed-out review tasks can be requeued with original instructions.'
      return
    end

    card.with_lock do
      card.requeue_with_original_instructions!(source: 'kanban_board')
    end

    if request.xhr? || request.format.json?
      render json: { ok: true, requeuedId: card.id, status: card.status }
    else
      redirect_to kanban_path, notice: 'Task requeued with original instructions.'
    end
  end

  def submit_feedback_and_requeue
    card = KanbanCard.find(params[:id])

    if card.active == false
      return render json: { error: 'Task is already archived.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Task is already archived.'
      return
    end

    feedback = params[:feedback].to_s

    card.with_lock do
      card.submit_feedback_and_requeue!(feedback: feedback, source: 'kanban_board')
    end

    if request.xhr? || request.format.json?
      render json: { ok: true, requeuedId: card.id, status: card.status }
    else
      redirect_to kanban_path, notice: 'Task feedback submitted and requeued.'
    end
  rescue ArgumentError => e
    if request.xhr? || request.format.json?
      render json: { error: e.message }, status: :unprocessable_entity
    else
      redirect_to kanban_path, alert: e.message
    end
  end

  def move_backlog
    card = KanbanCard.find(params[:id])

    if card.active == false
      return render json: { error: 'Task is already archived.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Task is already archived.'
      return
    end

    target_status = params[:target_status].to_s

    unless card.status.in?(%w[queued icebox]) && target_status.in?(%w[queued icebox])
      return render json: { error: 'Only queued and icebox tasks can be moved here.' }, status: :unprocessable_entity if request.xhr? || request.format.json?

      redirect_to kanban_path, alert: 'Only queued and icebox tasks can be moved here.'
      return
    end

    card.move_between_backlog_states!(target_status: target_status, source: 'kanban_board')

    if request.xhr? || request.format.json?
      render json: { ok: true, movedId: card.id, status: card.status }
    else
      redirect_to kanban_path, notice: "Task moved to #{card.status.humanize}."
    end
  rescue ArgumentError => e
    if request.xhr? || request.format.json?
      render json: { error: e.message }, status: :unprocessable_entity
    else
      redirect_to kanban_path, alert: e.message
    end
  end

  private

  def load_board!
    @updated_at = Time.current
    @selected_project = params[:project_id].to_s.presence
    @project_options = Project.ordered.to_a
    @selected_project_name = selected_project_name
    @new_card ||= build_manual_card(default_project_id: @selected_project)

    @columns = {
      'icebox' => filtered_manual_cards('icebox'),
      'queued' => filtered_manual_cards('queued'),
      'in_progress' => merged_in_progress_cards,
      'ready_for_review' => filtered_manual_cards('ready_for_review'),
      'complete' => filtered_manual_cards('complete')
    }
    @workers = worker_snapshot(@columns.fetch('in_progress'))
    @worker_desyncs = @workers.select { |worker| worker[:desynced] }
    @board_updated_at = board_updated_at
  end

  def filtered_manual_cards(status)
    scope = KanbanCard.board_visible.where(status: status)
    scope = apply_project_filter(scope)
    scope.ordered
  end

  def merged_in_progress_cards
    live_cards = filtered_live_in_progress_cards
    occupied_lanes = live_cards.map { |card| normalize_lane_key(card.lane) }.to_set
    manual_cards = filtered_manual_cards('in_progress').reject do |card|
      occupied_lanes.include?(normalize_lane_key(card.lane))
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
      manual_card = active_manual_card_for_lane(lane_key)
      next unless manual_card || task
      next unless manual_card

      project = manual_card.project || infer_project(task, lane_key)
      lane_label = lane_key.sub('marvin', 'Marvin ')
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
    %w[marvin1 marvin2 marvin3 marvin4 marvin5 marvin6 marvin7 marvin8]
  end

  def worker_snapshot(in_progress_cards = merged_in_progress_cards)
    cards_by_lane = in_progress_cards.each_with_object({}) do |card, out|
      lane_value = normalize_lane_key(card.try(:lane))
      next if lane_value.blank?

      out[lane_value] ||= card
    end

    lane_keys.map do |lane_key|
      heartbeat = heartbeat_info(lane_key)
      card = cards_by_lane[lane_key]
      task = heartbeat[:task].presence || card&.title
      missing_heartbeat = card.present? && heartbeat[:task].blank?
      stale_heartbeat = card.present? && heartbeat[:stale]

      {
        name: lane_key.sub('marvin', 'Marvin '),
        lane: lane_key,
        active: card.present?,
        task: task,
        card_id: card&.id,
        desynced: missing_heartbeat || stale_heartbeat,
        desync_reason: if missing_heartbeat
          'Heartbeat blank'
        elsif stale_heartbeat
          'Heartbeat stale'
        end,
        heartbeat_updated_at: heartbeat[:updated_at]
      }
    end
  end

  def selected_project_name
    if @selected_project == 'none'
      KanbanCard::NO_PROJECT
    elsif @selected_project.present?
      @project_options.find { |project| project.id.to_s == @selected_project.to_s }&.name || 'Selected project'
    else
      'All projects'
    end
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
    elsif text.include?('openclaw') || text.include?('devops') || text.include?('session') || text.include?('runtime')
      'DevOps'
    else
      nil
    end

    project_name.present? ? Project.find_by(name: project_name) : nil
  end

  def active_manual_card_for_lane(lane_key)
    lane_label = lane_key.sub('marvin', 'Marvin ')
    candidates = [lane_key.downcase, lane_label.downcase].uniq

    KanbanCard.where(status: 'in_progress', active: true)
      .where('LOWER(lane) IN (?) OR LOWER(worker) IN (?)', candidates, candidates)
      .order(updated_at: :desc)
      .first
  end

  def normalize_lane_key(value)
    text = value.to_s.strip.downcase
    return nil if text.blank?

    match = text.match(/marvin\s*(\d+)/)
    return "marvin#{match[1]}" if match

    text.delete(' ')
  end

  def heartbeat_info(lane_key)
    heartbeat_path = Rails.root.join('..', 'memory', lane_key, 'HEARTBEAT.md')
    text = File.read(heartbeat_path)
    match = text.match(/Active task:\s*(.+)/i)
    raw_task = match && match[1].to_s.gsub(/[*_`~]/, '').strip
    task = if raw_task.blank? || raw_task == '(none)' || raw_task.casecmp('none').zero?
      nil
    else
      raw_task
    end
    updated_at = File.mtime(heartbeat_path)

    {
      task: task,
      updated_at: updated_at,
      stale: updated_at < HEARTBEAT_STALE_AFTER.ago
    }
  rescue Errno::ENOENT
    {
      task: nil,
      updated_at: nil,
      stale: false
    }
  end

  def parse_heartbeat_task(path)
    lane_key = Pathname.new(path).dirname.basename.to_s
    heartbeat_info(lane_key)[:task]
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

  def build_manual_card(default_project_id: nil)
    attrs = manual_card_params.to_h
    project_id = attrs.delete('project_id').presence || default_project_id.presence

    KanbanCard.new(
      title: attrs['title'],
      description: attrs['description'],
      notes: attrs['notes'],
      status: attrs['status'].presence_in(%w[queued icebox]) || 'queued',
      active: true,
      project_id: project_id
    )
  end

  def manual_card_params
    return ActionController::Parameters.new.permit! unless params[:kanban_card]

    params.require(:kanban_card).permit(:title, :description, :notes, :status, :project_id)
  end
end
