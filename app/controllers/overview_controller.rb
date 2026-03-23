class OverviewController < ApplicationController
  def index
    @updated_at = Time.current
  end

  def stats
    render json: DashboardStatsService.fetch
  end
end
