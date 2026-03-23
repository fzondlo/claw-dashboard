require 'fileutils'

module MarvinQueue
  class CompletionMemory
    ROOT = Pathname.new('/home/ubuntu/.openclaw/workspace')

    def self.record!(card)
      return unless card.lane.to_s.start_with?('marvin') || card.worker.to_s.start_with?('marvin')
      return unless card.review_notes.present? || card.review_focus.present?

      path = ROOT.join('memory', 'marvin-shared', "#{Date.today.iso8601}.md")
      FileUtils.mkdir_p(path.dirname)
      summary = card.review_notes.presence || card.review_focus.to_s
      qa = Array(card.qa_urls).join(', ')
      line = [
        "- #{Time.current.utc.iso8601} card ##{card.task_number || card.id} (#{card.title}) on #{card.lane || card.worker}",
        ("notes: #{summary.to_s.gsub(/\s+/, ' ').strip}" if summary.present?),
        ("qa: #{qa}" if qa.present?)
      ].compact.join(' | ')
      File.open(path, 'a') { |f| f.puts(line) }
    end
  end
end
