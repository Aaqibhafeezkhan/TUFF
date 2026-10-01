require 'minitest/autorun'
require 'tmpdir'
require_relative 'benchmark_simple'

class SimpleBenchmarkTests < Minitest::Test
  def test_even_and_odd_medians_include_slow_runs
    assert_equal 7, median([100, 1, 7])
    assert_equal 5, median([9, 1])
  end

  def test_markdown_reports_median_and_range_without_inventing_a_cause
    Dir.mktmpdir do |dir|
      row = { 'label' => 'Fixture', 'decode_tokens_per_second' => 7,
              'decode_tokens_per_second_min' => 1, 'decode_tokens_per_second_max' => 100,
              'prefill_seconds' => 2, 'generated_tokens' => 10,
              'peak_rss_bytes' => 1048576, 'answers_paris' => true }
      path = File.join(dir, 'report.md')
      write_markdown(path, { 'system' => { 'commit' => 'abc' }, 'runs_per_model' => 3,
                             'results' => [row] })
      text = File.read(path)
      assert_includes text, '7.00 tok/s | 1.00..100.00'
      refute_includes text, 'window server'
      refute_includes text, 'best of'
      refute_includes text, '| correct |'
    end
  end
end
