#!/usr/bin/env ruby
# frozen_string_literal: true

# One short question, a fresh process per repetition, median and spread.
# This is the quick launch-lineup check. Scripts/benchmark_v2.rb remains the
# long three-run matrix for workload-by-workload reporting.

require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"
require "time"

ROOT = File.expand_path("..", __dir__)
require_relative "benchmark_models"

CLI = File.join(ROOT, ".build", "release", "TUFFCLI")
PROMPT = File.join(ROOT, "docs", "benchmark-prompts", "capital-of-france.json")
SEED = 20_260_721
FOOTER = /\[stop=(\S+) prefill=(\d+)tok\/([0-9.]+)s new=(\d+)tok decode=([0-9.]+)s tok\/s=([0-9.]+)\]/
MAX_RSS = /\s*(\d+)\s+maximum resident set size/

def safe_capture(*command)
  stdout, _stderr, status = Open3.capture3(*command, chdir: ROOT)
  status.success? ? stdout.strip : ""
end

def system_report
  {
    "commit" => safe_capture("git", "rev-parse", "HEAD"),
    "worktree_status" => safe_capture("git", "status", "--short"),
    "cli_sha256" => safe_capture("shasum", "-a", "256", CLI).split.first,
    "macos" => safe_capture("sw_vers", "-productVersion"),
    "swift" => safe_capture("swift", "--version").lines.first.to_s.strip,
    "physical_memory_bytes" => safe_capture("sysctl", "-n", "hw.memsize").to_i,
    "hardware" => safe_capture(
      "system_profiler", "SPHardwareDataType", "-detailLevel", "mini"
    ).lines.grep(/^\s*(Model Name|Model Identifier|Chip|Memory):/).map(&:strip),
    "captured_at" => Time.now.iso8601
  }
end

# Where the .gturbo installs live. Defaults to the repository's scratch
# directory; --model-root points the harness at another copy of the same
# installs, such as the ones the packaged app downloaded.
def model_path(config, root)
  return File.expand_path(config.fetch(:path), ROOT) if root.nil?

  File.join(root, File.basename(config.fetch(:path)))
end

def command_for(config, max_new, root)
  [
    "/usr/bin/time", "-l", CLI,
    "--model", model_path(config, root),
    "--messages-file", PROMPT,
    "--max-new", max_new.to_s,
    "--max-context", "4096",
    "--seed", SEED.to_s,
    *config.fetch(:chat),
    *config.fetch(:sampling),
    *config.fetch(:runtime)
  ]
end

# One measured run. `attempt` distinguishes the saved artifacts when a model is
# measured more than once.
def run_once(model, command, output_dir, attempt)
  FileUtils.mkdir_p(File.join(output_dir, model))
  suffix = attempt.zero? ? "run" : "run-#{attempt + 1}"
  prefix = File.join(output_dir, model, suffix)
  File.write("#{prefix}.command.txt", Shellwords.join(command) + "\n")

  started = Time.now
  stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
  File.binwrite("#{prefix}.stdout.txt", stdout)
  File.binwrite("#{prefix}.stderr.txt", stderr)
  raise "#{model} exited #{status.exitstatus}" unless status.success?

  footer = stderr.match(FOOTER)
  raise "#{model} printed no timing footer" unless footer

  rss = stderr.match(MAX_RSS)
  raise "#{model} printed no peak RSS" unless rss

  [footer, rss, stdout.strip, (Time.now - started).round(2)]
end

def machine_state
  JSON.parse(safe_capture("python3", "-c",
    "import sys,json;sys.path.insert(0,'Scripts');from benchmark_reporting import machine_state;print(json.dumps(machine_state()))"))
end

def median(values)
  sorted = values.sort
  mid = sorted.length / 2
  sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def measure(model, config, output_dir, max_new, root, repeat)
  command = command_for(config, max_new, root)
  runs = repeat.times.map do |attempt|
    before = machine_state
    footer, rss, answer, wall = run_once(model, command, output_dir, attempt)
    suffix = attempt.zero? ? "run" : "run-#{attempt + 1}"
    stderr = File.read(File.join(output_dir, model, "#{suffix}.stderr.txt"))
    settings = stderr[/^\[resolved inference settings\] (.*)$/, 1]
    {
      "attempt" => attempt + 1, "stop_reason" => footer[1],
      "prompt_tokens" => footer[2].to_i, "prefill_seconds" => footer[3].to_f,
      "generated_tokens" => footer[4].to_i, "decode_seconds" => footer[5].to_f,
      "decode_tokens_per_second" => footer[6].to_f,
      "peak_rss_bytes" => rss[1].to_i, "wall_seconds" => wall,
      "answers_paris" => answer.match?(/\bParis\b/i), "answer" => answer,
      "resolved_settings" => settings && JSON.parse(settings),
      "machine_state_before" => before, "machine_state_after" => machine_state
    }
  end
  rates = runs.map { |run| run.fetch("decode_tokens_per_second") }
  row = runs.first.merge(
    "model" => model, "label" => BENCHMARK_MODEL_LABELS.fetch(model, model),
    "decode_tokens_per_second" => median(rates),
    "decode_tokens_per_second_all_runs" => rates,
    "decode_tokens_per_second_min" => rates.min,
    "decode_tokens_per_second_max" => rates.max,
    "decode_tokens_per_second_spread" => rates.max - rates.min,
    "runs" => repeat, "all_runs" => runs,
    "prefill_seconds" => median(runs.map { |run| run.fetch("prefill_seconds") }),
    "peak_rss_bytes" => runs.map { |run| run.fetch("peak_rss_bytes") }.max,
    "answers_paris" => runs.all? { |run| run.fetch("answers_paris") },
    "command" => Shellwords.join(command))
  row["statistics"] = %w[decode_tokens_per_second prefill_seconds decode_seconds wall_seconds peak_rss_bytes].to_h do |field|
    values = runs.map { |run| run.fetch(field) }
    [field, { "values" => values, "median" => median(values),
              "minimum" => values.min, "maximum" => values.max,
              "spread" => values.max - values.min }]
  end
  row["wall_seconds"] = row.fetch("statistics").fetch("wall_seconds").fetch("median")
  row["decode_seconds"] = row.fetch("statistics").fetch("decode_seconds").fetch("median")
  puts "#{model}: median #{median(rates)} tok/s, range #{rates.min}..#{rates.max}, #{repeat} runs"
  row
end

def write_markdown(path, report)
  lines = [
    "# TUFF launch-lineup decode rates",
    "",
    "Commit: `#{report.dig("system", "commit")}`",
    "",
    "One fresh process per model answering \"What is the capital of France?\"",
    "from `docs/benchmark-prompts/capital-of-france.json`, seed #{SEED}, 4,096-token",
    "context. Decode rate excludes install, load, and prefill. Median of",
    "#{report.fetch("runs_per_model")} runs; every repetition and min/max spread are saved.",
    "These are short keyword smoke checks, not quality or sustained performance validation.",
    "Machine-state probes are observations; slower runs have no inferred cause.",
    "",
    "| Model | Median decode | Min..max | Prefill | Generated | Peak RSS | Answer |",
    "| --- | ---: | --- | ---: | ---: | ---: | --- |"
  ]
  report.fetch("results").each do |row|
    lines << format(
      "| %s | %.2f tok/s | %.2f..%.2f | %.2f s | %d tok | %.0f MiB | %s |",
      row.fetch("label"),
      row.fetch("decode_tokens_per_second"),
      row.fetch("decode_tokens_per_second_min"),
      row.fetch("decode_tokens_per_second_max"),
      row.fetch("prefill_seconds"),
      row.fetch("generated_tokens"),
      row.fetch("peak_rss_bytes") / 1_048_576.0,
      row.fetch("answers_paris") ? "named Paris" : "did not name Paris"
    )
  end
  File.write(path, lines.join("\n") + "\n")
end

if $PROGRAM_NAME == __FILE__

options = {
  models: BENCHMARK_MODELS.keys,
  model_root: nil,
  repeat: 3,
  max_new: 128,
  output: File.join(ROOT, "benchmark-results", "simple-#{Time.now.strftime("%Y%m%d-%H%M%S")}")
}

OptionParser.new do |parser|
  parser.banner = "Usage: Scripts/benchmark_simple.rb [options]"
  parser.on("--model NAME", BENCHMARK_MODELS.keys, "Measure one launch model") do |model|
    options[:models] = [model]
  end
  parser.on("--models NAMES", Array, "Measure these launch models") do |names|
    unknown = names - BENCHMARK_MODELS.keys
    raise OptionParser::InvalidArgument, unknown.join(",") unless unknown.empty?

    options[:models] = names
  end
  parser.on("--model-root DIR", "Directory holding the .gturbo installs") do |dir|
    options[:model_root] = File.expand_path(dir)
  end
  parser.on("--repeat N", Integer, "Runs per model; median and spread are reported (default 3)") do |n|
    raise OptionParser::InvalidArgument, n.to_s unless n.positive?

    options[:repeat] = n
  end
  parser.on("--max-new N", Integer, "Generated-token cap (default 128)") { |n| options[:max_new] = n }
  parser.on("--output PATH", "Result directory") { |path| options[:output] = File.expand_path(path) }
end.parse!

abort "release CLI is missing; run swift build -c release" unless File.executable?(CLI)
abort "benchmark prompt is missing: #{PROMPT}" unless File.file?(PROMPT)
options[:models].each do |model|
  path = model_path(BENCHMARK_MODELS.fetch(model), options[:model_root])
  abort "installed model is missing: #{path}" unless File.directory?(path)
end
busy = safe_capture("pgrep", "-fl", "TUFFServer|TUFFDecodeService|TUFFCLI")
abort "a TUFF model process is already running:\n#{busy}" unless busy.empty?

FileUtils.mkdir_p(options[:output])
report = { "prompt" => "What is the capital of France?", "seed" => SEED,
           "max_new_tokens" => options[:max_new], "model_root" => options[:model_root],
           "runs_per_model" => options[:repeat],
           "system" => system_report, "results" => [] }

options[:models].each do |model|
  report["results"] << measure(model, BENCHMARK_MODELS.fetch(model), options[:output],
                               options[:max_new], options[:model_root], options[:repeat])
  File.write(File.join(options[:output], "results.json"), JSON.pretty_generate(report) + "\n")
  write_markdown(File.join(options[:output], "summary.md"), report)
end

puts "\nwrote #{File.join(options[:output], "summary.md")}"

end
