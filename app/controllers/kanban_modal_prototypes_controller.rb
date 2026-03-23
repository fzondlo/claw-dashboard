class KanbanModalPrototypesController < ApplicationController
  VARIANTS = {
    'clean-sheet' => {
      name: 'Clean sheet',
      eyebrow: 'Modal Prototype A',
      description: 'Light, spacious modal with a bold amber review banner and clear action hierarchy.'
    },
    'dark-card' => {
      name: 'Dark card',
      eyebrow: 'Modal Prototype B',
      description: 'High-contrast dark header with a warm review callout and clean content area.'
    },
    'split-panel' => {
      name: 'Split panel',
      eyebrow: 'Modal Prototype C',
      description: 'Two-column layout with metadata on the left and review actions pinned to the right.'
    }
  }.freeze

  def show
    @variant = params[:variant].to_s
    @meta = VARIANTS[@variant]
    raise ActionController::RoutingError, 'Not Found' unless @meta
  end
end
