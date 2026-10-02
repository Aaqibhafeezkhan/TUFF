#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the repository's GitHub configuration without contacting GitHub:
#
# - every issue form parses, has unique field ids, and only uses labels listed
#   in .github/issue-routing.json, so routing never names a missing label;
# - every "Area" option in the forms has a routing entry, and every routing
#   entry is still offered by some form;
# - every workflow parses, declares top-level permissions, and never checks
#   out pull request code from a `pull_request_target` or `workflow_run`
#   job, which run with repository secrets;

require "json"
require "yaml"

# TUFF_CHECK_ROOT lets the regression tests point this at a fixture tree.
ROOT = ENV.fetch("TUFF_CHECK_ROOT", File.expand_path("..", __dir__))
FORMS = Dir[File.join(ROOT, ".github/ISSUE_TEMPLATE/*.yml")].sort
WORKFLOWS = Dir[File.join(ROOT, ".github/workflows/*.yml")].sort
ROUTING = JSON.parse(File.read(File.join(ROOT, ".github/issue-routing.json")))

$failures = []
def fail!(message)
  $failures << message
end

def relative(path)
  path.delete_prefix("#{ROOT}/")
end

known_labels = ROUTING.fetch("labels").keys
offered_areas = []

FORMS.each do |path|
  name = relative(path)
  document = YAML.safe_load(File.read(path))
  next if File.basename(path) == "config.yml"

  %w[name description body].each do |key|
    fail!("#{name}: missing #{key}") unless document[key]
  end
  Array(document["labels"]).each do |label|
    fail!("#{name}: label '#{label}' is not in issue-routing.json") unless known_labels.include?(label)
  end
  ids = []
  Array(document["body"]).each do |field|
    next if field["type"] == "markdown"

    id = field["id"]
    fail!("#{name}: a #{field['type']} field has no id") unless id
    fail!("#{name}: duplicate field id '#{id}'") if ids.include?(id)
    ids << id
    label = field.dig("attributes", "label")
    fail!("#{name}: field '#{id}' has no label") if label.to_s.empty?
    if field["type"] == "dropdown"
      options = Array(field.dig("attributes", "options"))
      fail!("#{name}: dropdown '#{id}' has no options") if options.empty?
      fail!("#{name}: dropdown '#{id}' repeats an option") if options.uniq.length != options.length
      if label == "Area"
        offered_areas.concat(options)
        options.each do |option|
          fail!("#{name}: Area option '#{option}' has no route") unless ROUTING["areas"].key?(option)
        end
      end
    end
  end
end

(ROUTING["areas"].keys - offered_areas).each do |option|
  fail!("issue-routing.json: area '#{option}' is not offered by any form")
end
ROUTING["areas"].each do |option, labels|
  labels.each do |label|
    fail!("issue-routing.json: '#{option}' routes to unknown label '#{label}'") unless known_labels.include?(label)
  end
end

PRIVILEGED_EVENTS = %w[pull_request_target workflow_run].freeze

WORKFLOWS.each do |path|
  name = relative(path)
  source = File.read(path)
  document = YAML.safe_load(source, aliases: false)
  # YAML 1.1 reads a bare `on:` key as boolean true.
  triggers = document["on"] || document[true]
  fail!("#{name}: no triggers") unless triggers
  fail!("#{name}: no top-level permissions") unless document.key?("permissions")
  events = case triggers
           when String then [triggers]
           when Array then triggers
           when Hash then triggers.keys
           else []
           end
  privileged = (events & PRIVILEGED_EVENTS).any?
  Hash(document["jobs"]).each do |job_name, job|
    Array(job["steps"]).each do |step|
      next unless step["uses"].to_s.start_with?("actions/checkout")

      ref = step.dig("with", "ref").to_s
      if privileged
        fail!("#{name}: job '#{job_name}' checks out untrusted pull request code with secrets available")
      end
    end
  end
  if privileged && source.match?(/\bswift (build|test)\b|Scripts\/test\.sh|package_app\.sh/)
    fail!("#{name}: a privileged workflow must not build or run repository code")
  end
end

if $failures.empty?
  puts "GitHub configuration: #{FORMS.length} issue files and #{WORKFLOWS.length} workflows checked"
else
  warn $failures.join("\n")
  exit 1
end
