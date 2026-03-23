require 'fileutils'
require 'time'

module MarvinQueue
  class WorkerBootstrapContext
    ROOT = Pathname.new('/home/ubuntu/.openclaw/workspace')
    LOCK_PATH = Rails.root.join('tmp', 'marvin_worker_bootstrap.lock')
    FILES = %w[AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md].freeze
    RESTORE_DELAY_SECONDS = 8

    def self.with_minimal_context
      new.with_minimal_context { yield }
    end

    def with_minimal_context
      FileUtils.mkdir_p(LOCK_PATH.dirname)
      File.open(LOCK_PATH, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        backups = backup_current_files
        write_minimal_files
        yield
        sleep RESTORE_DELAY_SECONDS
      ensure
        restore_files(backups) if backups
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    private

    def backup_current_files
      FILES.to_h do |name|
        path = ROOT.join(name)
        [name, File.exist?(path) ? File.binread(path) : nil]
      end
    end

    def restore_files(backups)
      backups.each do |name, content|
        path = ROOT.join(name)
        if content.nil?
          File.delete(path) if File.exist?(path)
        else
          File.binwrite(path, content)
        end
      end
    end

    def write_minimal_files
      FileUtils.mkdir_p(ROOT.join('memory', 'marvin-shared'))
      File.write(ROOT.join('AGENTS.md'), minimal_agents)
      File.write(ROOT.join('SOUL.md'), minimal_soul)
      File.write(ROOT.join('TOOLS.md'), minimal_tools)
      File.write(ROOT.join('IDENTITY.md'), minimal_identity)
      File.write(ROOT.join('USER.md'), minimal_user)
    end

    def minimal_agents
      <<~MD
        # AGENTS.md - Marvin Worker Context

        Keep replies short. Do the assigned task directly.

        ## Startup
        - You are an isolated Marvin worker, not a main assistant session.
        - Do not assume prior chat history.
        - Do not read MEMORY.md unless the task explicitly tells you to.
        - Use only the heartbeat path named in the task message.
        - Never write to any other lane heartbeat file.

        ## Working rules
        - Ship the smallest correct result fast.
        - Prefer direct edits and verification over long planning.
        - Keep durable notes in files, not chat.

        ## Completion memory
        - When the task is complete, ensure durable facts are captured.
        - Append concise durable notes only if they matter to future tasks.
        - Use `/home/ubuntu/.openclaw/workspace/memory/marvin-shared/#{Date.today.iso8601}.md`.
        - Skip memory writes if there is nothing durable worth keeping.
      MD
    end

    def minimal_soul
      <<~MD
        # SOUL.md

        You are Marvin: a fast, disposable worker session.
        Be direct, quiet, and competent.
      MD
    end

    def minimal_tools
      <<~MD
        # TOOLS.md

        Default project root: `/home/ubuntu/.openclaw/workspace`
        Dash app: `/home/ubuntu/.openclaw/workspace/dash-board`
      MD
    end

    def minimal_identity
      <<~MD
        # IDENTITY.md

        - **Name:** Marvin
        - **Creature:** worker agent
        - **Vibe:** fast, minimal, task-focused
        - **Emoji:** 🤖
      MD
    end

    def minimal_user
      <<~MD
        # USER.md

        - **Name:** Frank
        - **What to call them:** Frank
        - **Timezone:** UTC
        - **Notes:** Keep answers short. Do the task. Include a QA URL when you finish work.
      MD
    end
  end
end
