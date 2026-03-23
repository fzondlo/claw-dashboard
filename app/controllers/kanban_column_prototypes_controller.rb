class KanbanColumnPrototypesController < ApplicationController
  VARIANTS = {
    'soft-glass' => {
      name: 'Soft glass columns',
      eyebrow: 'Column Prototype A',
      description: 'Bright, airy columns with soft translucent cards and premium spacing.'
    },
    'editorial-rail' => {
      name: 'Editorial rail layout',
      eyebrow: 'Column Prototype B',
      description: 'Sharper vertical rails with stronger typography and cleaner card rhythm.'
    },
    'dark-ops' => {
      name: 'Dark ops board',
      eyebrow: 'Column Prototype C',
      description: 'A darker high-contrast concept that feels like a polished internal control room.'
    }
  }.freeze

  def show
    @updated_at = Time.current
    @variant = params[:variant].to_s
    @meta = VARIANTS[@variant]
    raise ActionController::RoutingError, 'Not Found' unless @meta
  end
end
