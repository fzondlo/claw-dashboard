require 'set'

module MarvinQueue
  class Watchdog
    ROOT = Pathname.new('/home/ubuntu/.openclaw/workspace')
    MIN_NUDGE_MS = 5.minutes.in_milliseconds
    BLANK_HEARTBEAT_TIMEOUT_MS = 5.minutes.in_milliseconds
    TIMEOUT_MS = 20.minutes.in_milliseconds

    def self.run
      new.run
    end

    def run
      state = StateStore.load
      scan_in_progress_cards!(state)
      reset_completed_lanes!(state)
      clear_orphan_heartbeats!(state)
      StateStore.save!(state)
      true
    end

    private

    def scan_in_progress_cards!(state)
      cards_in_progress.each do |card|
        heartbeat = heartbeat_info(card['lane'])
        now_ms = Time.current.to_f * 1000
        card_state = state.dig('watchdog', 'cards', card['id'].to_s) || {}
        last_nudge_at = card_state['lastNudgeAt'].to_i
        missing_heartbeat = heartbeat[:task].blank? || heartbeat[:task].casecmp('none').zero? || heartbeat[:task] == '(none)'
        stale_heartbeat = heartbeat[:mtime_ms].positive? && (now_ms - heartbeat[:mtime_ms] > MIN_NUDGE_MS)
        in_progress_since_ms = Time.zone.parse(card['in_progress_since'].to_s).to_f * 1000
        blank_heartbeat_timed_out = missing_heartbeat && in_progress_since_ms.positive? && (now_ms - in_progress_since_ms >= BLANK_HEARTBEAT_TIMEOUT_MS)
        timed_out = in_progress_since_ms.positive? && (now_ms - in_progress_since_ms >= TIMEOUT_MS)

        # Check DB as ground truth: if card already has timed_out_at set, skip (already handled).
        # Don't rely solely on in-memory state which can be lost on restart/rotation.
        already_timed_out_in_db = KanbanCard.where(id: card['id']).where.not(timed_out_at: nil).exists?

        if (timed_out || blank_heartbeat_timed_out) && card_state['timedOutAt'].blank? && !already_timed_out_in_db
          recommendation = timeout_recommendation(card, heartbeat)
          stop_lane_assignment(card['lane'])
          timeout_card!(card, heartbeat, recommendation)
          state['watchdog']['cards'][card['id'].to_s] = card_state.merge('lane' => card['lane'], 'timedOutAt' => now_ms)
          reason = timed_out ? 'timed out' : 'blank-heartbeat timed out'
          log("#{reason} card ##{card['id']} lane=#{card['lane']}")
          next
        end

        next unless (missing_heartbeat || stale_heartbeat) && (now_ms - last_nudge_at > MIN_NUDGE_MS)

        state['watchdog']['cards'][card['id'].to_s] = card_state.merge('lane' => card['lane'], 'lastNudgeAt' => now_ms)
        log("observed stale heartbeat for card ##{card['id']} lane=#{card['lane']} missing=#{missing_heartbeat} stale=#{stale_heartbeat}")
      end
    end

    def reset_completed_lanes!(state)
      active_lanes = cards_in_progress.map { |card| card['lane'].to_s.downcase }.to_set
      state.fetch('lanes', {}).each do |lane, lane_state|
        next if lane_state['completionResetAt'].present?
        next if active_lanes.include?(lane.to_s.downcase)

        card = KanbanCard.find_by(id: lane_state['cardId'])
        next unless card&.status.in?(%w[ready_for_review complete])

        stop_lane_assignment(lane)
        lane_state['completionResetAt'] = Time.current.utc.iso8601
        lane_state['finalStatus'] = card.status
        lane_state['completedCardId'] = card.id
        log("cleared #{lane} after isolated card ##{card.id} -> #{card.status}")
      rescue StandardError => e
        log("warning: failed to reset #{lane} after card ##{lane_state['cardId']}: #{e.message}")
      end
    end

    def cards_in_progress
      KanbanCard.where(status: 'in_progress', active: true).where.not(lane: [nil, '']).order(:id).map do |card|
        {
          'id' => card.id,
          'title' => card.title,
          'lane' => card.lane.to_s.downcase,
          'worker' => card.worker,
          'in_progress_since' => (card.in_progress_since || card.updated_at).iso8601,
          'updated_at' => card.updated_at.iso8601
        }
      end
    end

    def clear_orphan_heartbeats!(state)
      active_lanes = cards_in_progress.map { |card| card['lane'].to_s.downcase }.to_set

      (1..8).each do |n|
        lane = "marvin#{n}"
        next if active_lanes.include?(lane)

        heartbeat = heartbeat_info(lane)
        next if heartbeat[:task].blank?

        stop_lane_assignment(lane)
        state.fetch('lanes', {}).delete(lane)
        log("cleared orphan heartbeat for #{lane}")
      end
    end

    def heartbeat_info(lane)
      path = ROOT.join('memory', lane, 'HEARTBEAT.md')
      text = File.read(path)
      match = text.match(/Active task:\s*(.+)/i) || text.match(/\*\*Active task:\*\*\s*(.+)/i)
      task = match ? match[1].to_s.strip : '(none)'
      {
        task: task,
        mtime_ms: File.mtime(path).to_f * 1000,
        path: path.to_s
      }
    rescue Errno::ENOENT
      { task: '(none)', mtime_ms: 0, path: path.to_s }
    end

    def stop_lane_assignment(lane)
      path = ROOT.join('memory', lane, 'HEARTBEAT.md')
      FileUtils.mkdir_p(path.dirname)
      File.write(path, "Active task: (none)\n")
    end

    def timeout_recommendation(card, heartbeat)
      reasons = []
      reasons << 'heartbeat went blank' if heartbeat[:task].blank? || heartbeat[:task] == '(none)' || heartbeat[:task].casecmp('none').zero?
      reasons << 'heartbeat stopped updating' if heartbeat[:mtime_ms].positive? && ((Time.current.to_f * 1000) - heartbeat[:mtime_ms] > MIN_NUDGE_MS)
      reasons << 'work exceeded the 20 minute limit without landing review-ready output' if reasons.empty?

      [
        "#{card['title']} timed out because #{reasons.join(' and ')}.",
        "Retry on #{card['lane']} with a tighter slice and an explicit finish line.",
        'Ask the worker to ship the smallest reviewable increment first, post progress/activity every few minutes, and move the card to ready_for_review immediately once there is a QAable result.',
        'If the task is long-running or risky, split it into smaller queued cards instead of keeping one card in_progress past 20 minutes.'
      ].join(' ')
    end

    def timeout_card!(card, heartbeat, recommendation)
      timeout_metadata = {
        timedOutAt: Time.current.utc.iso8601,
        lane: card['lane'],
        worker: card['worker'],
        heartbeatTask: heartbeat[:task].presence || '(none)',
        heartbeatUpdatedAt: heartbeat[:mtime_ms].positive? ? Time.at(heartbeat[:mtime_ms] / 1000).utc.iso8601 : nil,
        reason: 'watchdog_timeout'
      }

      KanbanCard.find(card['id']).mark_timed_out!(
        timeout_recommendation: recommendation,
        requeue_recommendation: recommendation,
        metadata: timeout_metadata,
        activity_body: [
          "Timed out after #{TIMEOUT_MS / 60000} minutes in progress. Lane assignment was released and the card was moved to ready_for_review.",
          '',
          "Recommendation: #{recommendation}"
        ].join("\n")
      )
    end

    def log(message)
      Rails.logger.info("[marvin-watchdog] #{message}")
      FileUtils.mkdir_p(Rails.root.join('log'))
      File.open(Rails.root.join('log', 'marvin_queue.log'), 'a') { |f| f.puts("[#{Time.current.utc.iso8601}] #{message}") }
    end
  end
end
