class ProjectsController < ApplicationController
  def index
    @updated_at = Time.current
    @projects = Project.ordered
  end
end
