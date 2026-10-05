#!/usr/bin/env ruby

require "pathname"
require "set"
require "uri"

# Markdown is UTF-8 by definition, but Ruby picks its read encoding from the
# ambient locale. A shell with no LANG set reads these files as US-ASCII, and
# the first em dash in a doc aborts the whole check with an encoding error
# rather than a link report. Pin the encoding so the result does not depend on
# the environment the checker happens to run in.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = Pathname.new(File.expand_path("..", __dir__))

# Checks the Markdown Git tracks or has staged, so personal notes left
# untracked in a checkout do not fail the repository checks. Outside a Git
# checkout it falls back to every root and docs file.
def markdown_files(arguments)
  return arguments.map { |path| ROOT.join(path).cleanpath } unless arguments.empty?

  tracked = IO.popen(["git", "-C", ROOT.to_s, "ls-files", "-z", "--", "*.md", "docs/**/*.md"],
                     err: File::NULL, &:read)
  if $?.success?
    paths = tracked.split("\0").reject(&:empty?)
      .select { |path| !path.include?("/") || path.start_with?("docs/") }
      .map { |path| ROOT.join(path) }
  else
    paths = Dir[ROOT.join("*.md").to_s] + Dir[ROOT.join("docs/**/*.md").to_s]
    paths = paths.map { |path| Pathname.new(path) }
  end
  paths.select(&:file?).uniq.sort
end

def without_inline_code(line)
  line.gsub(/`+[^`]*`+/, "")
end

def github_heading_slug(heading)
  heading
    .gsub(/<[^>]*>/, "")
    .gsub(/!\[([^\]]*)\]\([^)]+\)/, "\\1")
    .gsub(/\[([^\]]+)\]\([^)]+\)/, "\\1")
    .gsub(/[`*_~]/, "")
    .downcase
    .gsub(/[^\p{L}\p{N}\s_-]/u, "")
    .strip
    .gsub(/\s+/, "-")
end

def anchors_for(path)
  anchors = Set.new
  slug_counts = Hash.new(0)
  in_fence = false

  path.each_line do |line|
    if line.lstrip.start_with?("```")
      in_fence = !in_fence
      next
    end
    next if in_fence

    line.scan(/\bid=["']([^"']+)["']/i).flatten.each { |id| anchors << id }

    match = line.match(/\A {0,3}\#{1,6}\s+(.+?)\s*\#*\s*\z/)
    next unless match

    base = github_heading_slug(match[1])
    next if base.empty?

    occurrence = slug_counts[base]
    anchors << (occurrence.zero? ? base : "#{base}-#{occurrence}")
    slug_counts[base] += 1
  end

  anchors
end

def local_targets(line)
  markdown = without_inline_code(line)
    .scan(/\[[^\]]*\]\((<[^>]+>|[^)\s]+)(?:\s+["'][^"']*["'])?\)/)
    .flatten
  html = line.scan(/<(?:a|img)\b[^>]*\b(?:href|src)=["']([^"']+)["']/i).flatten
  markdown + html
end

missing = []
files = markdown_files(ARGV)
anchor_cache = {}

files.each do |source|
  in_fence = false
  source.each_line.with_index(1) do |line, line_number|
    if line.lstrip.start_with?("```")
      in_fence = !in_fence
      next
    end
    next if in_fence

    local_targets(line).each do |raw_target|
      target = raw_target.delete_prefix("<").delete_suffix(">")
      next if target.empty?
      next if target.match?(%r{\A(?:https?:|mailto:|data:)})

      path, fragment = target.split("#", 2)
      resolved = path.empty? ? source : source.dirname.join(path).cleanpath
      unless resolved.exist?
        missing << "#{source.relative_path_from(ROOT)}:#{line_number} -> #{raw_target}"
        next
      end

      next if fragment.nil? || fragment.empty? || resolved.extname.downcase != ".md"

      anchor = URI::DEFAULT_PARSER.unescape(fragment)
      anchor_cache[resolved] ||= anchors_for(resolved)
      unless anchor_cache[resolved].include?(anchor)
        missing << "#{source.relative_path_from(ROOT)}:#{line_number} -> #{raw_target} (missing anchor)"
      end
    end
  end
end

if missing.empty?
  puts "checked #{files.count} Markdown files; all local links and anchors resolve"
  exit 0
end

warn missing.join("\n")
exit 1
