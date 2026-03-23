module MarvinQueue
  class DispatchKick
    def self.kick
      cmd = %(cd #{Rails.root} && bundle3.2 exec rails runner 'MarvinQueue::Dispatcher.run')
      pid = Process.spawn('/usr/bin/env', 'bash', '-lc', cmd, out: '/dev/null', err: '/dev/null')
      Process.detach(pid)
      pid
    rescue StandardError => e
      Rails.logger.warn("marvin dispatch kick failed: #{e.message}")
      nil
    end
  end
end
