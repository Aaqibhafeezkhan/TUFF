import unittest
from benchmark_reporting import resolved_settings, summarize, expert_io
from write_release_benchmarks import render


class ReportingTests(unittest.TestCase):
    def test_keeps_slow_runs_and_failures(self):
        rows = [dict(model='test', kind='paris', status=status, tps=tps)
                for status, tps in [('passed', 1), ('needs_review', 7), ('passed', 100)]]
        summary = summarize(rows)[0]
        self.assertEqual(summary['smoke_passes'], 2)
        self.assertEqual(summary['attempts'], 3)
        self.assertEqual(summary['tps'], dict(values=[1, 7, 100], median=7,
                                              minimum=1, maximum=100, spread=99))

    def test_even_median_and_missing_measurement(self):
        rows = [dict(model='test', kind='paris', status='timeout'),
                dict(model='test', kind='paris', status='passed', tps=2),
                dict(model='test', kind='paris', status='passed', tps=4)]
        self.assertEqual(summarize(rows)[0]['tps']['median'], 3)
        self.assertEqual(summarize(rows)[0]['prefill_seconds'], None)

    def test_public_report_keeps_all_runs_and_never_selects_best(self):
        rows = [dict(model='test', label='Test', kind='paris', status='passed', attempt=0,
                     tps=tps, prefill_seconds=1, peak_rss_bytes=1024,
                     manifest_sha256='fixture-manifest') for tps in (1, 7, 100)]
        report = dict(results=rows, started=0, identity=dict(cli_sha256='abc', source_sha256='def'))
        text = render(report, '6.0.2')
        self.assertIn('1.000, 7.000, 100.000 | 7.000 | 1.000..100.000', text)
        self.assertNotIn('Best of', text)
        self.assertIn('`fixture-manifest`', text)

    def test_logical_demand_and_prefetch_remain_separate(self):
        text = ('logical demand expert reads: 2, bytes: 4096, failures: 0\n'
                'logical prefetch expert reads: 3, bytes: 6144, failures: 1\n'
                'exposed prefetch wait: 12.5 ms\n')
        metrics = expert_io(text)
        self.assertEqual(metrics['demand']['bytes'], 4096)
        self.assertEqual(metrics['prefetch']['reads'], 3)
        self.assertEqual(metrics['prefetch']['failures'], 1)
        self.assertEqual(metrics['exposed_prefetch_wait_ms'], 12.5)
        self.assertEqual(expert_io(''), {})

    def test_public_report_preserves_machine_observations_and_missing_probes(self):
        row = dict(model='test', label='Test', kind='paris', status='timeout', attempt=0,
                   machine_state_before=dict(memory_pressure=dict(available=True,
                       value='System-wide memory free percentage: 42%'),
                       swap_usage=dict(available=True, value='used = 1.00M'),
                       vm_stat=dict(available=True,
                           value='Pageins: 10.\nPageouts: 20.\nSwapins: 30.\nSwapouts: 40.')),
                   machine_state_after=dict(memory_pressure=dict(available=False, value=None)))
        text = render(dict(results=[row], started=0,
                           identity=dict(cli_sha256='abc', source_sha256='def')), '6.0.2')
        self.assertIn('42% / unavailable', text)
        self.assertIn('used = 1.00M / unavailable', text)
        self.assertIn('10, 20, 30, 40 / unavailable', text)
        self.assertIn('timeout / unavailable', text)

    def test_reads_resolved_values(self):
        self.assertEqual(resolved_settings('[resolved inference settings] {"prefill_chunk_tokens":"2048"}\n'),
                         {'prefill_chunk_tokens': '2048'})
        self.assertIsNone(resolved_settings('no settings'))


if __name__ == '__main__':
    unittest.main()
