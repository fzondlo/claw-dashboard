class OverviewController < ApplicationController
  def index
    @updated_at = Time.current
  end

  def stats
    render json: DashboardStatsService.fetch
  end

  def summary
    render json: DashboardStatsService.fetch_summary
  end

  def details
    render json: DashboardStatsService.fetch_details
  end
end
