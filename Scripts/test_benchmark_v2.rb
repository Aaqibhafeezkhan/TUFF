require 'minitest/autorun'
require 'tmpdir'
require_relative 'benchmark_v2'

class MatrixReportingTests < Minitest::Test
  def test_summary_keeps_every_observation_and_spread
    rows = [1, 7, 100].map do |rate|
      { 'prompt_tokens' => 20, 'generated_tokens' => 10, 'stop_reason' => 'eos',
        'prefill_seconds' => 1, 'decode_seconds' => 2,
        'decode_tokens_per_second' => rate, 'peak_rss_bytes' => 1024 }
    end
    summary = summarize(rows)
    assert_equal 7, summary.fetch('median_decode_tokens_per_second')
    assert_equal [1, 7, 100], summary.dig('statistics', 'decode_tokens_per_second', 'values')
    assert_equal 99, summary.dig('statistics', 'decode_tokens_per_second', 'spread')
  end

  def test_fresh_and_resumed_runs_preserve_machine_evidence
    Dir.mktmpdir do |dir|
      footer = "[resolved inference settings] {\"prefill_chunk_tokens\":\"512\"}\n" \
               "[stop=eos prefill=20tok/1.00s new=10tok decode=2.00s tok/s=5.000]\n" \
               "1024 maximum resident set size\n"
      command = ['/usr/bin/ruby', '-e', 'STDERR.write(ARGV[0]);puts "Paris"', footer]
      fresh = run_once(dir, 'fixture', 'short', 'measured-1', command)
      resumed = existing_run(dir, 'fixture', 'short', 'measured-1', command)
      assert_kind_of Hash, fresh.fetch('machine_state_before')
      assert_equal fresh.fetch('machine_state_before'), resumed.fetch('machine_state_before')
      assert_equal fresh.fetch('machine_state_after'), resumed.fetch('machine_state_after')
      assert_equal '512', resumed.dig('resolved_settings', 'prefill_chunk_tokens')
    end
  end

  def test_parser_reads_the_resolved_chunk_instead_of_guessing_from_flags
    stderr = "[resolved inference settings] {\"prefill_chunk_tokens\":\"2048\"}\n" \
             "[stop=eos prefill=20tok/1.00s new=10tok decode=2.00s tok/s=5.000]\n" \
             "1024 maximum resident set size\n"
    result = parse_measurement(stderr)
    assert_equal '2048', result.dig('resolved_settings', 'prefill_chunk_tokens')
    assert_equal 5, result.fetch('decode_tokens_per_second')
    assert_raises(RuntimeError) { parse_measurement('missing measurement') }
  end
end
