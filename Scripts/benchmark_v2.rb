#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"
require "time"

ROOT = File.expand_path("..", __dir__)
CLI = File.join(ROOT, ".build", "release", "TUFFCLI")
require_relative "benchmark_models"

PROMPTS = File.join(ROOT, "docs", "benchmark-prompts", "real-generation-v1")

CASES = {
  "short-explanation" => 20_260_721,
  "medium-review" => 20_260_722,
  "long-synthesis" => 20_260_723
}.freeze

MODELS = BENCHMARK_MODELS

FOOTER = /\[stop=(\S+) prefill=(\d+)tok\/([0-9.]+)s new=(\d+)tok decode=([0-9.]+)s tok\/s=([0-9.]+)\]/
MAX_RSS = /\s*(\d+)\s+maximum resident set size/

def median(values)
  sorted = values.sort
  middle = sorted.length / 2
  sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end

def safe_capture(*command)
  stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
  [stdout.strip, stderr.strip, status.success?]
end

def machine_state
  stdout, _stderr, success = safe_capture("python3", "-c",
    "import sys,json;sys.path.insert(0,'Scripts');from benchmark_reporting import machine_state;print(json.dumps(machine_state()))")
  success ? JSON.parse(stdout) : { "available" => false }
end

def system_report
  commit, = safe_capture("git", "rev-parse", "HEAD")
  status, = safe_capture("git", "status", "--short")
  macos, = safe_capture("sw_vers")
  swift, = safe_capture("swift", "--version")
  memory, = safe_capture("sysctl", "-n", "hw.memsize")
  hardware, = safe_capture(
    "system_profiler", "SPHardwareDataType", "-detailLevel", "mini"
  )
  cli_sha256, = safe_capture("shasum", "-a", "256", CLI)
  filtered_hardware = hardware.lines.grep(
    /^\s*(Model Name|Model Identifier|Chip|Total Number of Cores|Memory):/
  ).map(&:strip)

  {
    "commit" => commit,
    "cli_sha256" => cli_sha256.split.first,
    "worktree_status" => status,
    "macos" => macos,
    "swift" => swift,
    "physical_memory_bytes" => memory.to_i,
    "hardware" => filtered_hardware,
    "captured_at" => Time.now.iso8601,
    "machine_state" => machine_state
  }
end

def command_for(model, model_config, case_id, seed, max_new)
  model_path = File.expand_path(model_config.fetch(:path), ROOT)
  prompt_path = File.join(PROMPTS, "#{case_id}.json")
  [
    "/usr/bin/time", "-l", CLI,
    "--model", model_path,
    "--messages-file", prompt_path,
    "--max-new", max_new.to_s,
    "--max-context", "4096",
    "--seed", seed.to_s,
    *model_config.fetch(:chat),
    *model_config.fetch(:sampling),
    *model_config.fetch(:runtime)
  ]
end

def parse_measurement(stderr)
  footer = stderr.match(FOOTER)
  raise "TUFFCLI did not print a timing footer" unless footer

  settings = stderr[/^\[resolved inference settings\] (.*)$/, 1]
  rss = stderr.match(MAX_RSS)
  raise "/usr/bin/time did not print peak RSS" unless rss

  {
    "resolved_settings" => settings && JSON.parse(settings),
    "stop_reason" => footer[1],
    "prompt_tokens" => footer[2].to_i,
    "prefill_seconds" => footer[3].to_f,
    "generated_tokens" => footer[4].to_i,
    "decode_seconds" => footer[5].to_f,
    "decode_tokens_per_second" => footer[6].to_f,
    "peak_rss_bytes" => rss[1].to_i
  }
end

def run_once(output_dir, model, case_id, label, command)
  run_dir = File.join(output_dir, model, case_id)
  FileUtils.mkdir_p(run_dir)
  prefix = File.join(run_dir, label)
  File.write("#{prefix}.command.txt", Shellwords.join(command) + "\n")

  puts "#{model} / #{case_id} / #{label}"
  before = machine_state
  stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
  File.binwrite("#{prefix}.stdout.txt", stdout)
  File.binwrite("#{prefix}.stderr.txt", stderr)
  raise "#{model} #{case_id} #{label} exited #{status.exitstatus}" unless status.success?

  after = machine_state
  File.write("#{prefix}.machine.json", JSON.pretty_generate({ "before" => before, "after" => after }) + "\n")
  measurement = parse_measurement(stderr)
  unless %w[endOfTurn eos].include?(measurement.fetch("stop_reason"))
    raise "#{model} #{case_id} #{label} stopped with #{measurement.fetch("stop_reason")}"
  end

  measurement.merge(
    "machine_state_before" => before,
    "machine_state_after" => after,
    "label" => label,
    "command" => Shellwords.join(command),
    "stdout_file" => File.basename("#{prefix}.stdout.txt"),
    "stderr_file" => File.basename("#{prefix}.stderr.txt")
  )
end

def existing_run(output_dir, model, case_id, label, command)
  prefix = File.join(output_dir, model, case_id, label)
  command_path = "#{prefix}.command.txt"
  stdout_path = "#{prefix}.stdout.txt"
  stderr_path = "#{prefix}.stderr.txt"
  return nil unless [command_path, stdout_path, stderr_path].all? { |path| File.file?(path) }
  return nil unless File.read(command_path).strip == Shellwords.join(command)

  measurement = parse_measurement(File.read(stderr_path))
  return nil unless %w[endOfTurn eos].include?(measurement.fetch("stop_reason"))

  machine_path = "#{prefix}.machine.json"
  state = File.file?(machine_path) ? JSON.parse(File.read(machine_path)) : {}
  puts "#{model} / #{case_id} / #{label} (resumed)"
  measurement.merge(
    "machine_state_before" => state["before"],
    "machine_state_after" => state["after"],
    "label" => label,
    "command" => Shellwords.join(command),
    "stdout_file" => File.basename(stdout_path),
    "stderr_file" => File.basename(stderr_path)
  )
rescue RuntimeError
  nil
end

def summarize(measurements)
  {
    "prompt_tokens" => measurements.first.fetch("prompt_tokens"),
    "generated_tokens" => measurements.map { |row| row.fetch("generated_tokens") },
    "stop_reasons" => measurements.map { |row| row.fetch("stop_reason") },
    "median_prefill_seconds" => median(measurements.map { |row| row.fetch("prefill_seconds") }),
    "median_decode_seconds" => median(measurements.map { |row| row.fetch("decode_seconds") }),
    "median_decode_tokens_per_second" => median(
      measurements.map { |row| row.fetch("decode_tokens_per_second") }
    ),
    "median_peak_rss_bytes" => median(measurements.map { |row| row.fetch("peak_rss_bytes") }),
    "statistics" => %w[prefill_seconds decode_seconds decode_tokens_per_second peak_rss_bytes].to_h do |field|
      values = measurements.map { |row| row.fetch(field) }
      [field, { "values" => values, "median" => median(values),
                "minimum" => values.min, "maximum" => values.max,
                "spread" => values.max - values.min }]
    end
  }
end

def write_markdown(path, report)
  lines = [
    "# TUFF v2 benchmark results",
    "",
    "Commit: `#{report.dig("system", "commit")}`",
    "",
    "#{report.dig("protocol", "warmups_per_case")} discarded warmup(s) preceded #{report.dig("protocol", "measured_runs_per_case")} measurements per case. All attempts, median and spread are saved; causes of slower runs are not inferred.",
    "Medians use every measured repetition; the JSON includes minimum, maximum and spread.",
    "",
    "| Model | Case | Prompt tokens | Generated tokens | Stop reasons | Prefill median | Decode median | Peak RSS median |",
    "| --- | --- | ---: | --- | --- | ---: | ---: | ---: |"
  ]
  report.fetch("models").each do |model, cases|
    cases.each do |case_id, details|
      row = details.fetch("summary")
      lines << format(
        "| %s | %s | %d | %s | %s | %.2f s | %.3f tok/s | %.1f MiB |",
        model,
        case_id,
        row.fetch("prompt_tokens"),
        row.fetch("generated_tokens").join(" / "),
        row.fetch("stop_reasons").join(" / "),
        row.fetch("median_prefill_seconds"),
        row.fetch("median_decode_tokens_per_second"),
        row.fetch("median_peak_rss_bytes") / 1_048_576.0
      )
    end
  end
  File.write(path, lines.join("\n") + "\n")
end

if $PROGRAM_NAME == __FILE__

options = {
  models: MODELS.keys,
  warmups: 1,
  runs: 3,
  max_new: 1_024,
  plan: false,
  resume: false,
  output: File.join(ROOT, "benchmark-results", "v2-#{Time.now.strftime("%Y%m%d-%H%M%S")}")
}

OptionParser.new do |parser|
  parser.banner = "Usage: Scripts/benchmark_v2.rb [options]"
  parser.on("--model NAME", MODELS.keys, "Benchmark one launch model") do |model|
    options[:models] = [model]
  end
  parser.on("--warmups N", Integer, "Warmups per case (default 1)") { |n| options[:warmups] = n }
  parser.on("--runs N", Integer, "Measured runs per case (default 3)") { |n| options[:runs] = n }
  parser.on("--max-new N", Integer, "Generated-token cap (default 1024)") { |n| options[:max_new] = n }
  parser.on("--output PATH", "Result directory") { |path| options[:output] = File.expand_path(path) }
  parser.on("--plan", "Print commands without running models") { options[:plan] = true }
  parser.on("--resume", "Continue a matching interrupted result directory") do
    options[:resume] = true
  end
end.parse!

abort "--warmups must be at least 1" if options[:warmups] < 1
abort "--runs must be at least 3" if options[:runs] < 3
abort "--max-new must be positive" if options[:max_new] < 1

options[:models].each do |model|
  config = MODELS.fetch(model)
  CASES.each do |case_id, seed|
    command = command_for(model, config, case_id, seed, options[:max_new])
    puts Shellwords.join(command) if options[:plan]
  end
end
exit 0 if options[:plan]

abort "release CLI is missing; run swift build -c release --product TUFFCLI" unless File.executable?(CLI)
options[:models].each do |model|
  model_path = File.expand_path(MODELS.fetch(model).fetch(:path), ROOT)
  abort "installed model is missing: #{model_path}" unless File.directory?(model_path)
end
CASES.each_key do |case_id|
  prompt = File.join(PROMPTS, "#{case_id}.json")
  abort "benchmark prompt is missing: #{prompt}" unless File.file?(prompt)
end

protocol = {
  "warmups_per_case" => options[:warmups],
  "measured_runs_per_case" => options[:runs],
  "max_new_tokens" => options[:max_new],
  "context_tokens" => 4_096
}
results_path = File.join(options[:output], "results.json")
if options[:resume]
  abort "resume results are missing: #{results_path}" unless File.file?(results_path)
  report = JSON.parse(File.read(results_path))
  abort "resume protocol does not match this invocation" unless report.fetch("protocol") == protocol
  current_system = system_report
  abort "resume commit does not match the current checkout" unless
    report.dig("system", "commit") == current_system.fetch("commit")
  if report.dig("system", "cli_sha256") &&
     report.dig("system", "cli_sha256") != current_system.fetch("cli_sha256")
    abort "resume CLI binary does not match the original run"
  end
else
  if File.directory?(options[:output]) && !Dir.empty?(options[:output])
    abort "output directory is not empty; choose another path or pass --resume"
  end
  FileUtils.mkdir_p(options[:output])
  report = {
    "protocol" => protocol,
    "system" => system_report,
    "models" => {}
  }
end
File.write(File.join(options[:output], "system.json"), JSON.pretty_generate(report.fetch("system")) + "\n")

options[:models].each do |model|
  config = MODELS.fetch(model)
  report["models"][model] ||= {}
  CASES.each do |case_id, seed|
    command = command_for(model, config, case_id, seed, options[:max_new])
    options[:warmups].times do |index|
      label = "warmup-#{index + 1}"
      existing_run(options[:output], model, case_id, label, command) ||
        run_once(options[:output], model, case_id, label, command)
    end
    measured = options[:runs].times.map do |index|
      label = "measured-#{index + 1}"
      existing_run(options[:output], model, case_id, label, command) ||
        run_once(options[:output], model, case_id, label, command)
    end
    report["models"][model][case_id] = {
      "measurements" => measured,
      "summary" => summarize(measured)
    }
    File.write(
      File.join(options[:output], "results.json"),
      JSON.pretty_generate(report) + "\n"
    )
    write_markdown(File.join(options[:output], "summary.md"), report)
  end
end

puts "Results: #{options[:output]}"

end
