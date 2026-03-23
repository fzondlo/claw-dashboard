require 'json'

module MarvinQueue
  class StateStore
    PATH = Rails.root.join('tmp', 'marvin_queue_state.json')

    def self.load
      data = JSON.parse(File.read(PATH))
      data['lanes'] ||= {}
      data['watchdog'] ||= {}
      data['watchdog']['cards'] ||= {}
      data
    rescue Errno::ENOENT, JSON::ParserError
      { 'lanes' => {}, 'watchdog' => { 'cards' => {} } }
    end

    def self.save!(state)
      FileUtils.mkdir_p(PATH.dirname)
      File.write(PATH, JSON.pretty_generate(state))
    end
  end
end
