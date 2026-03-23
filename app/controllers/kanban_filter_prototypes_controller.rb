class KanbanFilterPrototypesController < ApplicationController
  VARIANTS = {
    'split-pill' => {
      name: 'Split pill toolbar',
      eyebrow: 'Prototype A',
      description: 'Compact segmented chips with a single bold project chooser and utility actions tucked to the right.'
    },
    'glass-tabs' => {
      name: 'Glass tabs + search rail',
      eyebrow: 'Prototype B',
      description: 'A softer, premium toolbar with large tabs, a search shell, and a standout project control.'
    },
    'command-bar' => {
      name: 'Command bar',
      eyebrow: 'Prototype C',
      description: 'A denser control strip that feels more operational, with scope chips and action buttons inline.'
    }
  }.freeze

  def show
    @updated_at = Time.current
    @variant = params[:variant].to_s
    @meta = VARIANTS[@variant]
    raise ActionController::RoutingError, 'Not Found' unless @meta
  end
end
