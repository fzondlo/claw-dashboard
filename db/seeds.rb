projects_seed = [
  {
    name: "Dashboard",
    slug: "dash-board",
    repo: "dash-board",
    status: "Active",
    url: "https://dash.zevner.com/kanban",
    link_label: "Open kanban",
    description: "Internal Zevner operations dashboard for live lane activity, kanban flow, and quick visibility into what the team is actively shipping."
  },
  {
    name: "Raizia",
    slug: "raizia",
    repo: "raizia",
    status: "Active",
    url: "https://raizia.co/",
    link_label: "Open site",
    description: "Medellín-first property search and intelligence platform with public search, map exploration, property pages, and internal data collection tooling."
  },
  {
    name: "Medellín BNB Property Directory",
    slug: "medellin-monthly",
    repo: "medellin_monthly",
    status: "Active",
    url: "https://properties.zevner.com/",
    link_label: "Open site",
    description: "Monthly-rental property site for Medellín listings, powered by Hospitable syncs, property detail pages, localization, and booking-oriented merchandising."
  },
  {
    name: "TRA Portal",
    slug: "tra-portal",
    repo: "tra_portal",
    status: "Active",
    url: "https://tra.zevner.com/",
    link_label: "Open app",
    description: "Internal tourist-registration workflow app for reservation imports, admin review, and operational processing tied to Hospitable data."
  },
  {
    name: "DevOps",
    slug: "openclaw",
    repo: "openclaw",
    status: "Active",
    url: "https://dash.zevner.com/",
    link_label: "Open dashboard",
    description: "Core DevOps runtime, automation, session orchestration, and lane-management work."
  }
]

projects_by_name = projects_seed.each_with_object({}) do |attrs, memo|
  project = Project.find_or_initialize_by(slug: attrs.fetch(:slug))
  project.assign_attributes(attrs)
  project.save!
  memo[project.name] = project
end

def activity_entry(body, at:, kind: 'update', source: 'seed')
  {
    'body' => body,
    'created_at' => at.utc.iso8601,
    'kind' => kind,
    'source' => source
  }
end

kanban_seed = {
  queued: [
    {
      external_id: "OPS-101",
      title: "Review Pixi 7 runtime reload path",
      project_name: "DevOps",
      lane: "Pixi 7",
      worker: "Unassigned",
      description: "Validate the DeepSeek switch survives runtime reloads and reflects live dashboard state.",
      tags: %w[auth runtime]
    },
    {
      external_id: "OPS-102",
      title: "Audit idle lane session pressure",
      project_name: "DevOps",
      lane: "Shared",
      worker: "Unassigned",
      description: "Review stale Telegram and cron sessions that may be creating noise in the dashboard.",
      tags: %w[dashboard sessions]
    }
  ],
  ready_for_review: [],
  complete: [
    {
      external_id: "OPS-090",
      title: "Clean up stray OpenClaw cron sessions",
      project_name: "DevOps",
      lane: "Pixi 1",
      worker: "Pixi 1",
      description: "Removed noisy watchdog cron jobs and cleaned stale session entries so only real sessions remain visible.",
      review_focus: "QA by checking session count after cleanup and confirming active live sessions remained intact.",
      activity_entries: [
        activity_entry("Removed two live watchdog cron jobs and archived old cron run logs.", at: Time.zone.parse("2026-03-23 03:17:00 UTC")),
        activity_entry("QA by checking session count after cleanup and confirming active live sessions remained intact.", at: Time.zone.parse("2026-03-23 03:19:00 UTC"), kind: 'review')
      ],
      tags: %w[ops cleanup],
      completed_at: Time.zone.parse("2026-03-23 03:19:00 UTC")
    },
    {
      external_id: "OPS-091",
      title: "Fix stalled property enrichment job",
      project_name: "Raizia",
      lane: "Pixi 1",
      worker: "Pixi 1",
      description: "Restarted Sidekiq, reconciled stuck runs, and confirmed all properties were already enriched.",
      review_focus: "Manual verification still depends on Frank rerunning the UI flow if he wants to confirm the job now behaves as expected from the front end.",
      activity_entries: [
        activity_entry("Updated stale ImportRuns from running to failed and verified formatted addresses exist across the full dataset.", at: Time.zone.parse("2026-03-23 01:41:00 UTC")),
        activity_entry("Manual verification still depends on Frank rerunning the UI flow if he wants to confirm the job now behaves as expected from the front end.", at: Time.zone.parse("2026-03-23 01:45:00 UTC"), kind: 'review')
      ],
      tags: %w[raizia jobs],
      completed_at: Time.zone.parse("2026-03-23 01:45:00 UTC")
    }
  ],
  icebox: []
}

kanban_seed.each do |status, items|
  items.each_with_index do |attrs, index|
    project = projects_by_name[attrs.delete(:project_name)]
    card = KanbanCard.find_or_initialize_by(external_id: attrs.fetch(:external_id))
    card.assign_attributes(attrs.merge(status: status.to_s, sort_order: index, active: true, project: project))
    card.save!
  end
end
