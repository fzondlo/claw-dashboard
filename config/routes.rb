Rails.application.routes.draw do
  root "overview#index"
  get "/api/stats", to: "overview#stats"
  get "/kanban", to: "kanban_board#index"
  get "/kanban-v2", to: "kanban_board#preview_v2", as: :kanban_v2
  get "/kanban-v2/live-board", to: "kanban_board#board_v2", as: :live_kanban_board_v2
  get "/kanban/live-board", to: "kanban_board#board", as: :live_kanban_board
  get "/kanban/filter-prototypes/:variant", to: "kanban_filter_prototypes#show", as: :kanban_filter_prototype
  get "/kanban/column-prototypes/:variant", to: "kanban_column_prototypes#show", as: :kanban_column_prototype
  get "/kanban/modal-prototypes/:variant", to: "kanban_modal_prototypes#show", as: :kanban_modal_prototype
  get "/projects", to: "projects#index"
  get "/archive", to: "archived_tasks#index", as: :archive
  delete "/kanban/cards/archive_complete", to: "kanban_board#archive_complete", as: :archive_complete_kanban_cards
  patch "/kanban/cards/:id/complete", to: "kanban_board#mark_complete", as: :complete_kanban_card
  patch "/kanban/cards/:id/requeue_with_recommendation", to: "kanban_board#requeue_with_recommendation", as: :requeue_with_recommendation_kanban_card
  patch "/kanban/cards/:id/requeue_with_original_instructions", to: "kanban_board#requeue_with_original_instructions", as: :requeue_with_original_instructions_kanban_card
  patch "/kanban/cards/:id/move_backlog", to: "kanban_board#move_backlog", as: :move_backlog_kanban_card
  delete "/kanban/cards/:id", to: "kanban_board#destroy", as: :delete_kanban_card
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
