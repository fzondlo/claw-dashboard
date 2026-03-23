require "base64"
require "json"
require "etc"
require "net/http"
require "open3"
require "openssl"
require "ostruct"
require "pathname"
require "set"
require "socket"
require "time"

class DashboardStatsService
  AGENTS_ROOT = Pathname.new("/home/ubuntu/.openclaw/agents")
  WORKSPACE_ROOT = Pathname.new("/home/ubuntu/.openclaw/workspace")
  EXTRA_PROFILES = WORKSPACE_ROOT.join("lobster-board/profiles-extra.json")
  SECRET_PROFILES = WORKSPACE_ROOT.join("lobster-board/profiles-secrets.json")
  SUMMARY_CACHE_KEY = "dashboard/stats/summary/v1"
  DETAILS_CACHE_KEY = "dashboard/stats/details/v1"
  SUMMARY_CACHE_TTL = 10.seconds
  DETAILS_CACHE_TTL = 60.seconds
  CPU_SAMPLE_CACHE_KEY = "dashboard/stats/cpu_sample/v1"

  class << self
    def fetch
      fetch_summary.merge(fetch_details)
    end

    def fetch_summary
      Rails.cache.fetch(SUMMARY_CACHE_KEY, expires_in: SUMMARY_CACHE_TTL) { new.fetch_summary }
    end

    def fetch_details
      Rails.cache.fetch(DETAILS_CACHE_KEY, expires_in: DETAILS_CACHE_TTL) { new.fetch_details }
    end
  end

  def fetch_summary
    mem_total = memory_total_bytes
    mem_free = memory_free_bytes
    mem_used = mem_total - mem_free
    sessions = build_sessions(load_session_store)

    {
      updatedAt: Time.current.iso8601,
      host: Socket.gethostname,
      cpuPercent: cpu_usage_percent,
      memory: {
        usedGb: bytes_to_gb(mem_used),
        totalGb: bytes_to_gb(mem_total),
        percent: percent(mem_used, mem_total)
      },
      disk: disk_stats,
      sessions: sessions
    }
  end

  def fetch_details
    status_text = safe_command("openclaw status")
    session_store = load_session_store
    per_agent_session_store = load_per_agent_session_store
    profiles = load_profiles
    lane_auth_truth = load_lane_auth_truth(per_agent_session_store)
    profile_lane_map = build_profile_lane_map_from_truth(lane_auth_truth, profiles)
    sessions = build_sessions(session_store)

    {
      updatedAt: Time.current.iso8601,
      channel: parse_channel(status_text),
      topTokens: sessions.sort_by { |row| -token_percent(row[:tokens]) }.first(8),
      usageProfiles: build_usage_profiles(profiles, profile_lane_map),
      laneAuthTruth: lane_auth_truth,
      laneContexts: build_lane_contexts(session_store),
      recommendations: [
        "Pinned session profile is the live truth when present",
        "Configured order is the fallback truth",
        "Observed last-used is shown separately so it cannot silently override the live pin"
      ]
    }
  end

  private

  def cpu_usage_percent
    current = cpu_sample_with_time
    previous = Rails.cache.read(CPU_SAMPLE_CACHE_KEY)
    Rails.cache.write(CPU_SAMPLE_CACHE_KEY, current, expires_in: 5.minutes)

    return load_average_cpu_fallback unless previous.is_a?(Hash)

    total_delta = current[:total] - previous[:total].to_i
    idle_delta = current[:idle] - previous[:idle].to_i
    elapsed = current[:captured_at].to_f - previous[:captured_at].to_f

    return load_average_cpu_fallback if total_delta <= 0 || elapsed <= 0

    (((total_delta - idle_delta).to_f / total_delta) * 100).round(1)
  rescue StandardError
    load_average_cpu_fallback
  end

  def cpu_sample_with_time
    sample = cpu_sample
    sample.merge(captured_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
  end

  def load_average_cpu_fallback
    load, = File.read("/proc/loadavg").split
    cpu_count = Etc.nprocessors
    return 0.0 if cpu_count.to_i <= 0

    ((load.to_f / cpu_count) * 100).round(1).clamp(0.0, 100.0)
  rescue StandardError
    0.0
  end

  def cpu_sample
    lines = File.read("/proc/stat").lines
    cpu = lines.find { |line| line.start_with?("cpu ") }
    values = cpu.to_s.split.drop(1).map(&:to_i)
    {
      total: values.sum,
      idle: values[3].to_i + values[4].to_i
    }
  end

  def memory_total_bytes
    extract_meminfo("MemTotal")
  end

  def memory_free_bytes
    extract_meminfo("MemAvailable")
  end

  def extract_meminfo(key)
    line = File.read("/proc/meminfo").lines.find { |entry| entry.start_with?("#{key}:") }
    line.to_s.split[1].to_i * 1024
  end

  def bytes_to_gb(value)
    (value.to_f / 1024 / 1024 / 1024).round(2)
  end

  def percent(value, total)
    return 0.0 if total.to_f <= 0

    ((value.to_f / total) * 100).round(1)
  end

  def disk_stats
    stdout = safe_command("df -h /home/ubuntu/.openclaw/workspace | tail -n 1").strip
    parts = stdout.split(/\s+/)
    {
      used: parts[2] || "?",
      avail: parts[3] || "?",
      percent: parts[4] || "?"
    }
  end

  def safe_command(command)
    stdout, stderr, status = Open3.capture3(command)
    output = [stdout, stderr].join
    status.success? ? stdout : output.presence || "command failed"
  rescue StandardError => e
    e.message.to_s
  end

  def parse_channel(status_text)
    rows = parse_box_table(status_text)
    telegram = rows.find { |row| row[0] == "Telegram" }
    { state: telegram&.[](2) || "unknown", detail: telegram&.[](3) || "not found" }
  end

  def parse_box_table(text)
    rows = []
    in_table = false

    text.to_s.each_line do |line|
      if line.include?("│ Channel") && line.include?("Enabled") && line.include?("State")
        in_table = true
        next
      end
      next unless in_table
      break if line.start_with?("└")
      next unless line.start_with?("│")

      cells = line.split("│")[1..-2].to_a.map(&:strip)
      rows << cells if cells.first.present? && cells.first != "Channel"
    end

    rows
  end

  def token_percent(token_string)
    token_string.to_s[/\((\d+)%\)/, 1].to_i
  end

  def build_sessions(session_store)
    session_store.filter_map do |key, entry|
      next unless key.to_s.include?(":telegram:") || key.to_s.include?(":cron:")

      {
        key: key,
        kind: entry["chatType"] || (key.to_s.include?(":group:") ? "group" : "direct"),
        age: session_age(entry["updatedAt"]),
        model: entry["model"] || "unknown",
        tokens: format_tokens(entry)
      }
    end.sort_by { |row| row[:age].to_s[/^(\d+)/, 1].to_i }
  end

  def format_tokens(entry)
    used = resolve_used_tokens(entry)
    max = resolve_context_window(entry["model"])
    pct = lane_context_percent(entry)
    "#{used || 'unknown'}/#{max} (#{pct || '?'}%)"
  end

  def session_age(updated_at)
    return "unknown" unless updated_at

    minutes = [((Time.current.to_f * 1000 - updated_at.to_f) / 60_000).round, 0].max
    "#{minutes}m ago"
  end

  def load_session_store
    AGENTS_ROOT.children.each_with_object({}) do |agent_dir, out|
      next unless agent_dir.directory?

      path = agent_dir.join("sessions/sessions.json")
      out.merge!(read_json(path, {})) if path.exist?
    end
  rescue StandardError
    {}
  end

  def load_per_agent_session_store
    AGENTS_ROOT.children.each_with_object({}) do |agent_dir, out|
      next unless agent_dir.directory?

      path = agent_dir.join("sessions/sessions.json")
      out[agent_dir.basename.to_s] = read_json(path, {}) if path.exist?
    end
  rescue StandardError
    {}
  end

  def read_json(path, fallback)
    JSON.parse(path.read)
  rescue StandardError
    fallback
  end

  def read_text(path)
    path.read
  rescue StandardError
    ""
  end

  def decode_jwt_payload(token)
    payload = token.to_s.split(".")[1]
    return {} if payload.blank?

    JSON.parse(Base64.urlsafe_decode64(payload))
  rescue StandardError
    {}
  end

  def load_profiles
    out = []
    seen = Set.new

    AGENTS_ROOT.children.each do |agent_dir|
      next unless agent_dir.directory?

      auth = read_json(agent_dir.join("agent/auth-profiles.json"), {})
      stats = auth["usageStats"] || {}
      add_profile_set(out, seen, auth.fetch("profiles", {}), stats)
    end

    add_array_profiles(out, seen, read_json(SECRET_PROFILES, []))
    add_array_profiles(out, seen, read_json(EXTRA_PROFILES, []))

    out.sort_by { |profile| [profile[:access].present? ? 0 : 1, -profile[:lastUsed].to_i] }
  end

  def add_profile_set(out, seen, profiles_hash, stats)
    profiles_hash.each do |id, profile|
      push_profile(out, seen, { "id" => id }.merge(profile), stats[id] || {})
    end
  end

  def add_array_profiles(out, seen, profiles)
    profiles.each { |profile| push_profile(out, seen, profile, {}) }
  end

  def push_profile(out, seen, profile, stats)
    return unless profile["provider"] == "openai-codex"
    return if profile["id"].blank? || seen.include?(profile["id"])

    payload = decode_jwt_payload(profile["access"])
    email = payload.dig("https://api.openai.com/profile", "email") || profile["email"] || profile["id"]

    out << {
      id: profile["id"],
      email: email,
      lastUsed: stats["lastUsed"],
      accountId: profile["accountId"],
      access: profile["access"].to_s,
      placeholder: profile["access"].blank?
    }
    seen << profile["id"]
  end

  def build_usage_profiles(profiles, profile_lane_map)
    profiles.map do |profile|
      live = fetch_codex_usage(profile)
      {
        profileId: profile[:id],
        email: profile[:email],
        todayLeft: live[:todayLeft],
        weekLeft: live[:weekLeft],
        todayReset: live[:todayReset],
        weekReset: live[:weekReset],
        storedOnly: live[:storedOnly],
        swimlanes: profile_lane_map[profile[:id]] || []
      }
    end
  end

  def fetch_codex_usage(profile)
    return { todayLeft: nil, weekLeft: nil, todayReset: nil, weekReset: nil, storedOnly: true } if profile[:access].blank?

    uri = URI("https://chatgpt.com/backend-api/wham/usage")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 3
    http.read_timeout = 3
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{profile[:access]}"
    request["User-Agent"] = "Dash"
    request["Accept"] = "application/json"
    request["ChatGPT-Account-Id"] = profile[:accountId] if profile[:accountId].present?

    response = http.request(request)
    return { todayLeft: nil, weekLeft: nil, todayReset: nil, weekReset: nil, storedOnly: false } unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    primary = data.dig("rate_limit", "primary_window")
    secondary = data.dig("rate_limit", "secondary_window")

    {
      todayLeft: primary ? 100 - clamp_percent(primary["used_percent"]) : nil,
      weekLeft: secondary ? 100 - clamp_percent(secondary["used_percent"]) : nil,
      todayReset: primary ? format_remaining(primary["reset_after_seconds"]) : nil,
      weekReset: secondary ? format_remaining(secondary["reset_after_seconds"]) : nil,
      storedOnly: false
    }
  rescue StandardError
    { todayLeft: nil, weekLeft: nil, todayReset: nil, weekReset: nil, storedOnly: false }
  end

  def clamp_percent(value)
    [[value.to_f.round, 0].max, 100].min
  end

  def format_remaining(seconds)
    total = seconds.to_i
    return nil if total.negative?

    days = total / 86_400
    hours = (total % 86_400) / 3600
    minutes = (total % 3600) / 60
    return "#{days}d #{hours}h" if days.positive?
    return "#{hours}h #{minutes}m" if hours.positive?

    "#{minutes}m"
  end

  def provider_from_model(model)
    value = model.to_s.downcase
    return nil if value.blank?
    return value.split("/").first if value.include?("/")
    return "openai-codex" if value.start_with?("gpt-") || value.include?("openai")
    return "anthropic" if value.start_with?("claude") || value.include?("anthropic")
    return "google" if value.start_with?("gemini") || value.include?("google")
    return "custom-api-deepseek-com" if value.start_with?("deepseek")

    nil
  end

  def load_lane_auth_truth(per_agent_session_store)
    per_agent_session_store.each_with_object([]) do |(agent_id, store), out|
      next unless agent_id.match?(/^(pixi|marvin)[1-8]$/)

      auth = read_json(AGENTS_ROOT.join("#{agent_id}/agent/auth-profiles.json"), {})
      models = read_json(AGENTS_ROOT.join("#{agent_id}/agent/models.json"), {})
      usage_stats = auth["usageStats"] || {}
      default_model = models["default"]
      default_provider = provider_from_model(default_model) || default_model.to_s.split("/").first
      configured_order = auth.dig("order", default_provider).presence || []
      configured_profile = configured_order.first || (default_provider == "google" ? "google:default" : nil)

      last_used_profile, last_used_at = usage_stats.max_by { |_profile_id, stats| stats["lastUsed"].to_i } || [nil, { "lastUsed" => 0 }]
      last_used_at_value = last_used_at["lastUsed"].to_i

      agent_entries = store.select { |key, _entry| key.to_s.start_with?("agent:#{agent_id}:") }
      telegram_entries = agent_entries.select { |key, _entry| key.to_s.include?(":telegram:") }
      preferred_entries = if agent_id.start_with?("pixi")
        telegram_entries.presence || agent_entries
      else
        agent_entries
      end

      if preferred_entries.empty?
        lane = normalize_lane_name(agent_id, agent_id.sub(/^pixi/, "Pixi ").sub(/^marvin/, "Marvin "))
        model = default_model || "unknown"
        compatible_last_used = provider_from_model(model) == "openai-codex" ? last_used_profile : nil
        out << {
          agentId: agent_id,
          lane: lane,
          key: nil,
          model: model,
          configuredProfile: configured_profile,
          pinnedProfile: nil,
          pinnedSource: nil,
          liveProfile: configured_profile || compatible_last_used,
          lastUsedProfile: compatible_last_used,
          lastUsedAt: last_used_at_value.positive? ? last_used_at_value : nil,
          updatedAt: nil,
          status: configured_profile.present? ? "configured" : compatible_last_used.present? ? "observed" : "unknown"
        }
        next
      end

      preferred_entries.each do |key, entry|
        lane = lane_name_for_session(key, entry)
        pinned_profile = entry["authProfileOverride"]
        model = entry["model"] || default_model || "unknown"
        compatible_last_used = provider_from_model(model) == "openai-codex" ? last_used_profile : nil
        out << {
          agentId: agent_id,
          lane: lane,
          key: key,
          model: model,
          configuredProfile: configured_profile,
          pinnedProfile: pinned_profile,
          pinnedSource: entry["authProfileOverrideSource"],
          liveProfile: pinned_profile || configured_profile || compatible_last_used,
          lastUsedProfile: compatible_last_used,
          lastUsedAt: last_used_at_value.positive? ? last_used_at_value : nil,
          updatedAt: format_iso(entry["updatedAt"]),
          status: pinned_profile.present? ? "pinned" : configured_profile.present? ? "configured" : compatible_last_used.present? ? "observed" : "unknown"
        }
      end
    end.sort_by { |row| row[:lane] }
  end

  def build_profile_lane_map_from_truth(lane_auth_truth, profiles)
    map = profiles.index_with { [] }
    by_id = profiles.index_by { |profile| profile[:id] }

    lane_auth_truth.each do |row|
      profile_id = row[:liveProfile] || row[:configuredProfile] || row[:lastUsedProfile]
      next if profile_id.blank?
      next unless by_id[profile_id]

      map[by_id[profile_id]] << {
        name: row[:lane],
        model: row[:model] || "unknown",
        pct: nil,
        used: 0,
        max: 0,
        displayProfile: format_provider_label(profile_id, row[:model])
      }
    end

    map.transform_values do |lanes|
      lanes.uniq { |lane| lane[:name] }.sort_by { |lane| lane[:name] }
    end.transform_keys { |profile| profile[:id] }
  end

  def build_lane_contexts(session_store)
    rows = []

    session_store.each do |key, entry|
      next unless key.to_s.match?(/^agent:(pixi|marvin)[1-8]:/)
      next if key.to_s.match?(/^agent:pixi[1-8]:/) && !key.to_s.include?(":telegram:")

      name = lane_name_for_session(key, entry)
      next if rows.any? { |row| row[:name] == name }

      rows << {
        name: name,
        model: entry["model"] || "unknown",
        percent: lane_context_percent(entry) || 0,
        used: resolve_used_tokens(entry) || 0,
        max: resolve_context_window(entry["model"]),
        updatedAt: format_iso(entry["updatedAt"])
      }
    end

    rows.sort_by { |row| row[:name] }
  end

  def resolve_context_window(model)
    value = model.to_s.downcase
    return 272_000 if value.include?("gpt-5.4")
    return 400_000 if value.include?("gpt-5.1")
    return 200_000 if value.include?("claude")

    272_000
  end

  def resolve_used_tokens(entry)
    total = entry["totalTokens"].to_i
    return total if total.positive?

    sum = entry.values_at("inputTokens", "outputTokens", "cacheRead", "cacheWrite").sum(&:to_i)
    sum.positive? ? sum : nil
  end

  def lane_context_percent(entry)
    used = resolve_used_tokens(entry)
    return nil unless used

    ((used.to_f / resolve_context_window(entry["model"])) * 100).round.clamp(0, 100)
  end

  def normalize_lane_name(key, raw)
    text = raw.to_s.downcase
    return "Marvin 8" if key.to_s.include?("agent:marvin8:") || text.include?("marvin8") || text.include?("marvin 8")
    return "Marvin 7" if key.to_s.include?("agent:marvin7:") || text.include?("marvin7") || text.include?("marvin 7")
    return "Marvin 6" if key.to_s.include?("agent:marvin6:") || text.include?("marvin6") || text.include?("marvin 6")
    return "Marvin 5" if key.to_s.include?("agent:marvin5:") || text.include?("marvin5") || text.include?("marvin 5")
    return "Marvin 4" if key.to_s.include?("agent:marvin4:") || text.include?("marvin4") || text.include?("marvin 4")
    return "Marvin 3" if key.to_s.include?("agent:marvin3:") || text.include?("marvin3") || text.include?("marvin 3")
    return "Marvin 2" if key.to_s.include?("agent:marvin2:") || text.include?("marvin2") || text.include?("marvin 2")
    return "Marvin 1" if key.to_s.include?("agent:marvin1:") || text.include?("marvin1") || text.include?("marvin 1")
    return "Pixi 1" if key.to_s.include?("agent:pixi1:") || key.to_s.include?("telegram:direct:6449879040") || text.include?("pixi1")

    raw
  end

  def lane_name_for_session(key, entry)
    raw = entry["subject"] || entry["displayName"]&.sub(/^telegram:g-/, "") || entry.dig("origin", "label")&.sub(/ id:[^ ]+$/, "") || (key.to_s.include?("telegram:direct:") ? "Main DM" : key)
    normalize_lane_name(key, raw)
  end

  def format_provider_label(profile_id, model)
    profile = profile_id.to_s
    model_name = model.to_s.strip
    return model_name.sub(/^google\//, "Gemini ") if profile.start_with?("google:") && model_name.start_with?("google/")
    return "Gemini #{model_name}" if profile.start_with?("google:") && model_name.present? && model_name != "unknown"
    return "Gemini" if profile.start_with?("google:")
    return "DeepSeek #{profile.split('/')[1..].join('/')}" if profile.start_with?("custom-api-deepseek-com/")

    profile.presence || "—"
  end

  def format_iso(milliseconds)
    return nil if milliseconds.blank?

    Time.at(milliseconds.to_f / 1000).utc.iso8601
  rescue StandardError
    nil
  end
end
