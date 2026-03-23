# Dash Board

Internal dashboard app for tracking active projects and workstreams.

## Current pages

- `/` - overview
- `/kanban` - kanban board
- `/projects` - project directory with links to active apps/sites

## Stack

- Ruby on Rails
- SQLite (development/test default)
- Tailwind-style server-rendered UI

## Local setup

```bash
bundle install
bin/rails db:prepare
bin/rails server -p 8790
```

Then open:

- `http://127.0.0.1:8790/`
- `http://127.0.0.1:8790/projects`

## Key files

- `app/controllers/projects_controller.rb` - projects page data
- `app/views/projects/index.html.erb` - projects page UI
- `app/views/layouts/_sidebar.html.erb` - shared sidebar nav
- `config/routes.rb` - app routes

## Deployment notes

This app is deployed behind Caddy and is reachable at:

- `https://dash.zevner.com/`

After app changes, restart/redeploy the dash app so the live site picks up updates.
