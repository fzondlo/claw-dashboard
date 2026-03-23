require 'json'
require 'open3'
require 'time'

module MarvinQueue
  class OpenclawClient
    OPENCLAW = '/home/ubuntu/.npm-global/bin/openclaw'
    ROOT = '/home/ubuntu/.openclaw/workspace'
    AGENTS_ROOT = Pathname.new('/home/ubuntu/.openclaw/agents')

    def self.enqueue_isolated_turn!(agent:, name:, message:, thinking: 'low', timeout_seconds: 1200)
      at = (Time.now.utc + 5).iso8601
      args = [
        OPENCLAW, 'cron', 'add',
        '--agent', agent,
        '--name', name,
        '--session', 'isolated',
        '--light-context',
        '--no-deliver',
        '--delete-after-run',
        '--at', at,
        '--thinking', thinking,
        '--timeout-seconds', timeout_seconds.to_s,
        '--message', message,
        '--json'
      ]

      stdout, stderr, status = Open3.capture3(*args, chdir: ROOT)
      raise "openclaw cron add failed for #{agent}: #{stderr.presence || stdout}" unless status.success?

      JSON.parse(stdout)
    end

    def self.normalize_session_bookkeeping!(agent)
      sessions_path = AGENTS_ROOT.join(agent, 'sessions', 'sessions.json')
      data = JSON.parse(File.read(sessions_path))
      changed = false

      data.each_value do |entry|
        session_file = entry['sessionFile'].to_s
        next if session_file.blank?
        next unless File.exist?(session_file)

        actual_id = File.basename(session_file, '.jsonl')
        next if actual_id.blank?

        if entry['sessionId'] != actual_id
          entry['sessionId'] = actual_id
          changed = true
        end
      end

      File.write(sessions_path, JSON.pretty_generate(data)) if changed
      changed
    rescue Errno::ENOENT, JSON::ParserError => e
      Rails.logger.warn("marvin session bookkeeping normalize failed for #{agent}: #{e.message}")
      false
    end
  end
end
