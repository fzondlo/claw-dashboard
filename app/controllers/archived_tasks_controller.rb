class ArchivedTasksController < ApplicationController
  def index
    @updated_at = Time.current
    base_scope = KanbanCard.where(active: false).includes(:project)

    @filter_options = {
      projects: archived_project_options(base_scope),
      statuses: base_scope.where.not(status: [nil, '']).distinct.order(:status).pluck(:status),
      lanes: base_scope.where.not(lane: [nil, '']).distinct.order(:lane).pluck(:lane),
      workers: base_scope.where.not(worker: [nil, '']).distinct.order(:worker).pluck(:worker)
    }

    @filters = filter_params.to_h.symbolize_keys
    @archived_cards = apply_filters(base_scope).ordered
    @archived_count = base_scope.count
    @filtered_count = @archived_cards.count
    @timed_out_count = base_scope.timed_out.count
    @active_filter_count = @filters.values.count(&:present?)
  end

  private

  def filter_params
    params.permit(:query, :project_id, :status, :lane, :worker, :outcome, :archived_from, :archived_to)
  end

  def apply_filters(scope)
    filtered = scope

    if @filters[:query].present?
      query = "%#{ActiveRecord::Base.sanitize_sql_like(@filters[:query].strip)}%"
      filtered = filtered.where(
        "title ILIKE :query OR description ILIKE :query OR summary ILIKE :query OR notes ILIKE :query OR review_notes ILIKE :query OR review_focus ILIKE :query",
        query: query
      )
    end

    filtered = filter_by_project(filtered)
    filtered = filtered.where(status: @filters[:status]) if @filters[:status].present?
    filtered = filtered.where(lane: @filters[:lane]) if @filters[:lane].present?
    filtered = filtered.where(worker: @filters[:worker]) if @filters[:worker].present?

    case @filters[:outcome]
    when 'timed_out'
      filtered = filtered.where.not(timed_out_at: nil)
    when 'normal'
      filtered = filtered.where(timed_out_at: nil)
    end

    if @filters[:archived_from].present?
      from_date = Date.parse(@filters[:archived_from]) rescue nil
      filtered = filtered.where('updated_at >= ?', from_date.beginning_of_day) if from_date
    end

    if @filters[:archived_to].present?
      to_date = Date.parse(@filters[:archived_to]) rescue nil
      filtered = filtered.where('updated_at <= ?', to_date.end_of_day) if to_date
    end

    filtered
  end

  def filter_by_project(scope)
    project_id = @filters[:project_id].to_s
    return scope if project_id.blank?
    return scope.where(project_id: nil) if project_id == 'none'

    scope.where(project_id: project_id)
  end

  def archived_project_options(scope)
    projects = scope.joins(:project).merge(Project.order(:name)).distinct.pluck('projects.name', 'projects.id')
    projects.unshift(['No project', 'none']) if scope.where(project_id: nil).exists?
    projects
  end
end
