class ProjectsController < ApplicationController
  def index
    @updated_at = Time.current
    @projects = [
      {
        name: "Dashboard",
        slug: "dash-board",
        description: "Internal Zevner operations dashboard for live lane activity, kanban flow, and quick visibility into what the team is actively shipping.",
        status: "Active",
        repo: "dash-board",
        url: "https://dash.zevner.com/kanban",
        link_label: "Open kanban"
      },
      {
        name: "Raizia",
        slug: "raizia",
        description: "Medellín-first property search and intelligence platform with public search, map exploration, property pages, and internal data collection tooling.",
        status: "Active",
        repo: "raizia",
        url: "https://raizia.co/",
        link_label: "Open site"
      },
      {
        name: "Medellín BNB Property Directory",
        slug: "medellin-monthly",
        description: "Monthly-rental property site for Medellín listings, powered by Hospitable syncs, property detail pages, localization, and booking-oriented merchandising.",
        status: "Active",
        repo: "medellin_monthly",
        url: "https://properties.zevner.com/",
        link_label: "Open site"
      },
      {
        name: "TRA Portal",
        slug: "tra-portal",
        description: "Internal tourist-registration workflow app for reservation imports, admin review, and operational processing tied to Hospitable data.",
        status: "Active",
        repo: "tra_portal",
        url: "https://tra.zevner.com/",
        link_label: "Open app"
      }
    ]
  end
end
