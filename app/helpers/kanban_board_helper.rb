require 'cgi'

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
    markdown = content.to_s
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
end
