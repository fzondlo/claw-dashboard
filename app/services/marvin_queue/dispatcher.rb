require 'set'

module MarvinQueue
  class Dispatcher
    WORKERS = (1..8).map { |n| { 'name' => "marvin#{n}", 'lane' => "marvin#{n}" } }.freeze
    ROOT = Pathname.new('/home/ubuntu/.openclaw/workspace')

    def self.run
      new.run
    end

    def run
      state = StateStore.load
      cards = queued_cards
      free_workers = available_workers

      return log('no queued cards') if cards.empty?

      assignments = []
      cards.each do |card|
        break if free_workers.empty?
        assignments << [card, free_workers.shift]
      end
      return log('no free workers') if assignments.empty?

      WorkerBootstrapContext.with_minimal_context do
        assignments.each do |card, worker|
          begin
            claim_card!(card, worker)
            job = dispatch_card(card, worker)

            state['lanes'][worker['lane']] = {
              'worker' => worker['name'],
              'cardId' => card['id'],
              'cardTitle' => card['title'],
              'assignedAt' => Time.current.utc.iso8601,
              'dispatchMode' => 'isolated_cron',
              'cronJobId' => job['id'],
              'lightContext' => true,
              'minimalWorkerContext' => true,
              'completionResetAt' => nil,
              'finalStatus' => nil
            }

            log("enqueued isolated cron turn for #{worker['name']}, claimed card ##{card['id']}, job=#{job['id']}")
          rescue StandardError => e
            release_card!(card)
            log("failed to dispatch card ##{card['id']} on #{worker['lane']}: #{e.message}")
          end
        end
      end

      StateStore.save!(state)
      true
    end

    private

    def queued_cards
      blocked_ids = existing_dispatched_card_ids

      KanbanCard.board_visible.where(status: 'queued').ordered.limit(20).filter_map do |card|
        next if blocked_ids.include?(card.id)

        {
          'id' => card.id,
          'title' => card.title,
          'summary' => card.summary.to_s,
          'notes' => '',
          'project_name' => card.project&.name.to_s,
          'timeout_recommendation' => card.timeout_recommendation.to_s
        }
      end
    end
    def available_workers
      occupied = KanbanCard.where(status: 'in_progress', active: true).where.not(lane: [nil, '']).pluck(:lane).map(&:downcase).to_set
      WORKERS.select do |worker|
        heartbeat_task(worker['lane']).blank? && !occupied.include?(worker['lane'].downcase)
      end
    end

    def heartbeat_task(lane)
      text = File.read(ROOT.join('memory', lane, 'HEARTBEAT.md'))
      match = text.match(/Active task:\s*(.+)/i) || text.match(/\*\*Active task:\*\*\s*(.+)/i)
      return nil unless match

      task = match[1].to_s.gsub(/[*_`~]/, '').strip
      return nil if task.blank? || task == '(none)' || task.casecmp('none').zero?

      task
    rescue Errno::ENOENT
      nil
    end

    def claim_card!(card, worker)
      KanbanCard.find(card['id']).claim_for_worker!(worker: worker['name'], lane: worker['lane'], occurred_at: Time.current)
    end

    def dispatch_card(card, worker)
      heartbeat_path = "/home/ubuntu/.openclaw/workspace/memory/#{worker['lane']}/HEARTBEAT.md"
      memory_path = "/home/ubuntu/.openclaw/workspace/memory/marvin-shared/#{Date.today.iso8601}.md"

      message = [
        "Dash kanban card ##{card['id']}: #{card['title']}",
        ("Project: #{card['project_name']}" if card['project_name'].present?),
        ("Summary: #{card['summary']}" if card['summary'].present?),
        ("Notes: #{card['notes']}" if card['notes'].present?),
        ("Timeout recommendation for this retry: #{card['timeout_recommendation']}" if card['timeout_recommendation'].present?),
        "You are #{worker['lane']}.",
        "Use only this heartbeat file: #{heartbeat_path}",
        'Do not write to any pixi heartbeat file or any other lane file.',
        'You own this card now. Do the work unless blocked.',
        'Immediately update your own lane heartbeat using the exact lane path above.',
        "The board should stay in 'in_progress' while you work.",
        'All jobs must report real card activity. Do not finish a task without leaving at least one substantive activity update that explains what you did, what changed, key notes/decisions, and anything Frank should know.',
        'If Frank added new activity/feedback on the card, read it and respond to it explicitly in your work and in your activity updates. Do not ignore card activity.',
        'During multi-step work, post progress/activity updates as you go, not just at the very end, unless the task is truly tiny.',
        'When done, default to ready_for_review and include at least one QA URL in review_notes.',
        'Do not only write a generic done/QA-link update. The activity log must say what was actually done.',
        'If this card is a research / recommendation / strategy task, put the actual answer directly into the card activity so Frank can read it in the modal.',
        'When you put substantive notes or research into card activity, write clean readable Markdown (headings, paragraphs, lists) so the modal renders it nicely and it is easy to review.',
        'If there is any durable lesson/decision worth keeping, append one concise bullet to this memory file before you finish: ' + memory_path,
        'As soon as you finish and update the card, clear your own heartbeat file back to Active task: (none).',
        'This task is running in an isolated non-main worker session with light context and a minimal worker bootstrap. Do not assume prior chat history.',
        'Use this exact command:',
        %(cd /home/ubuntu/.openclaw/workspace/dash-board && ruby script/kanban_card_update.rb #{card['id']} ready_for_review --worker #{worker['name']} --lane #{worker['lane']} --review-notes "<very short result + https://... QA URL>"),
        'Only use status complete after Frank reviews or if he explicitly says no review is needed.'
      ].compact.join("\n")

      OpenclawClient.enqueue_isolated_turn!(
        agent: worker['lane'],
        name: "kanban-card-#{card['id']}-#{worker['lane']}",
        message: message,
        thinking: 'low',
        timeout_seconds: 1200
      )
    end

    def release_card!(card)
      record = KanbanCard.find(card['id'])
      record.update!(status: 'queued', worker: nil, lane: nil, in_progress_since: nil)
    end

    def existing_dispatched_card_ids
      jobs_path = Pathname.new('/home/ubuntu/.openclaw/cron/jobs.json')
      payload = JSON.parse(File.read(jobs_path))
      jobs = payload.is_a?(Hash) ? Array(payload['jobs']) : []

      jobs.filter_map do |job|
        next unless job['enabled']

        name = job['name'].to_s
        next unless name.start_with?('kanban-card-')

        card_id = name.split('-')[2].to_i
        card_id if card_id.positive?
      end.to_set
    rescue Errno::ENOENT, JSON::ParserError
      Set.new
    end

    def log(message)
      Rails.logger.info("[marvin-dispatcher] #{message}")
      FileUtils.mkdir_p(Rails.root.join('log'))
      File.open(Rails.root.join('log', 'marvin_queue.log'), 'a') { |f| f.puts("[#{Time.current.utc.iso8601}] #{message}") }
    end
  end
end
