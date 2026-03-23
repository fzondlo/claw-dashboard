require 'cgi'
require 'nokogiri'

module KanbanBoardHelper
  MARKDOWN_OPTIONS = {
    parse: { smart: true },
    render: {
      unsafe: false,
      github_pre_lang: true,
      hardbreaks: true
    },
    extension: {
      strikethrough: true,
      table: true,
      autolink: true,
      tagfilter: true
    }
  }.freeze

  def review_links_for(item)
    text = [item.try(:review_notes), item.try(:review_focus), item.try(:description)]
      .concat(Array(item.try(:activity_entries_list)).map { |entry| entry[:body] })
      .compact
      .join("\n")

    text.scan(%r{https?://[^\s<>"]+}).uniq
  end

  def render_markdown(content)
    markdown = normalize_markdownish_content(content)
    return '<p>—</p>'.html_safe if markdown.blank?

    html = Commonmarker.to_html(markdown, options: MARKDOWN_OPTIONS)
    sanitize(
      html,
      tags: %w[p br strong em del code pre blockquote ul ol li h1 h2 h3 h4 h5 h6 a hr table thead tbody tr th td],
      attributes: %w[href rel target class]
    )
  end

  def markdown_plain_text(content)
    strip_tags(render_markdown(content.to_s)).squish
  end

  def html_attribute_escape(value)
    CGI.escapeHTML(value.to_s)
  end

  def activity_feed_preview(item)
    entry = item.try(:activity_entries_list)&.first
    return 'Open for full details.' unless entry

    markdown_plain_text(entry[:body]).presence || 'Open for full details.'
  end

  def activity_feed_html(item)
    entries = Array(item.try(:activity_entries_list))
    return '<p>—</p>'.html_safe if entries.empty?

    content_tag(:div, class: 'space-y-3') do
      safe_join(entries.map { |entry| activity_entry_html(entry) })
    end
  end

  def activity_entry_html(entry)
    timestamp = entry[:created_at]&.utc&.strftime('%Y-%m-%d %H:%M UTC') || 'Time unknown'
    kind = entry[:kind].to_s.tr('_', ' ').presence || 'Update'

    content_tag(:article, class: 'rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-sm') do
      safe_join([
        content_tag(:div, class: 'flex flex-wrap items-center justify-between gap-2') do
          safe_join([
            content_tag(:span, kind.titleize, class: 'inline-flex items-center rounded-full bg-slate-100 px-2.5 py-1 text-[11px] font-semibold text-slate-700'),
            content_tag(:time, timestamp, class: 'text-xs font-medium text-slate-500')
          ])
        end,
        content_tag(:div, render_markdown(entry[:body]), class: 'markdown-body mt-3 text-sm leading-6 text-slate-700')
      ])
    end
  end

  def in_progress_elapsed_badge_state(since, now: Time.current)
    elapsed_minutes = in_progress_elapsed_minutes(since, now: now)
    return :danger if elapsed_minutes > 12
    return :warning if elapsed_minutes > 7

    :normal
  end

  def in_progress_elapsed_badge_classes(since, now: Time.current)
    case in_progress_elapsed_badge_state(since, now: now)
    when :danger
      'bg-red-100 text-red-900 ring-red-200'
    when :warning
      'bg-amber-100 text-amber-900 ring-amber-200'
    else
      'bg-emerald-50 text-emerald-700 ring-emerald-100'
    end
  end

  def in_progress_elapsed_badge_label(since, now: Time.current)
    elapsed_minutes = in_progress_elapsed_minutes(since, now: now)
    elapsed_minutes < 1 ? '< 1 min' : pluralize(elapsed_minutes, 'min')
  end

  def completion_duration_label(item)
    seconds = item.try(:completion_duration_seconds_value)
    return if seconds.blank?

    format_duration_compact(seconds)
  end

  def format_duration_compact(total_seconds)
    seconds = total_seconds.to_i
    return if seconds.negative?
    return '0m' if seconds < 60

    hours = seconds / 3600
    minutes = (seconds % 3600) / 60

    return "#{hours}h #{minutes}m" if hours.positive? && minutes.positive?
    return "#{hours}h" if hours.positive?

    "#{minutes}m"
  end

  def kanban_sort_defaults
    {
      'icebox' => 'oldest',
      'queued' => 'oldest',
      'in_progress' => 'oldest',
      'ready_for_review' => 'newest',
      'complete' => 'newest'
    }
  end

  def kanban_sort_timestamp_for(item, column_key)
    timestamp = case column_key.to_s
    when 'ready_for_review', 'complete'
      item.try(:completed_at) || item.try(:updated_at) || item.try(:created_at) || item.try(:in_progress_since)
    when 'in_progress'
      item.try(:updated_at) || item.try(:in_progress_since) || item.try(:created_at)
    else
      item.try(:created_at) || item.try(:updated_at) || item.try(:completed_at) || item.try(:in_progress_since)
    end

    timestamp&.utc&.iso8601(6)
  end

  private

  def in_progress_elapsed_minutes(since, now: Time.current)
    return 0 unless since

    [((now - since) / 60).round, 0].max
  end

  def normalize_markdownish_content(content)
    text = content.to_s
    return '' if text.blank?
    return text unless html_like_content?(text)

    html_fragment_to_markdownish(text)
  end

  def html_like_content?(content)
    content.to_s.match?(%r{</?[a-z][^>]*>}i)
  end

  def html_fragment_to_markdownish(content)
    fragment = Nokogiri::HTML::DocumentFragment.parse(content.to_s)
    markdown = fragment.children.map { |node| markdownish_for_node(node) }.join
    markdown.lines.map(&:rstrip).join("\n").gsub(/\n{3,}/, "\n\n").strip
  end

  def markdownish_for_node(node, list_depth = 0)
    return node.text.to_s.gsub(/\s+/, ' ') if node.text?
    return '' unless node.element?

    inner = node.children.map { |child| markdownish_for_node(child, list_depth + (node.name.in?(%w[ul ol]) ? 1 : 0)) }.join.strip

    case node.name.downcase
    when 'br'
      "\n"
    when 'p', 'div', 'section', 'article'
      inner.present? ? "#{inner}\n\n" : ''
    when 'strong', 'b'
      inner.present? ? "**#{inner}**" : ''
    when 'em', 'i'
      inner.present? ? "*#{inner}*" : ''
    when 'code'
      inner.present? ? "`#{inner}`" : ''
    when 'pre'
      inner.present? ? "```\n#{node.text.to_s.strip}\n```\n\n" : ''
    when 'a'
      href = node['href'].to_s.strip
      return inner if href.blank?
      label = inner.presence || href
      "[#{label}](#{href})"
    when 'ul'
      render_list(node, ordered: false, depth: list_depth)
    when 'ol'
      render_list(node, ordered: true, depth: list_depth)
    when 'li'
      inner
    when 'h1'
      inner.present? ? "# #{inner}\n\n" : ''
    when 'h2'
      inner.present? ? "## #{inner}\n\n" : ''
    when 'h3'
      inner.present? ? "### #{inner}\n\n" : ''
    when 'h4', 'h5', 'h6'
      inner.present? ? "#### #{inner}\n\n" : ''
    when 'blockquote'
      inner.lines.map { |line| line.strip.present? ? "> #{line.strip}" : '>' }.join("\n") + "\n\n"
    else
      inner
    end
  end

  def render_list(node, ordered:, depth: 0)
    items = node.element_children.select { |child| child.name.downcase == 'li' }
    return '' if items.empty?

    indent = '  ' * [depth - 1, 0].max
    rendered = items.each_with_index.map do |item, index|
      marker = ordered ? "#{index + 1}." : '-'
      body = item.children.map { |child| markdownish_for_node(child, depth) }.join.strip
      next if body.blank?

      lines = body.lines.map(&:rstrip)
      first = lines.shift
      formatted = ["#{indent}#{marker} #{first}"]
      formatted.concat(lines.map { |line| line.present? ? "#{indent}  #{line}" : '' })
      formatted.join("\n")
    end.compact

    rendered.join("\n") + "\n\n"
  end
end
