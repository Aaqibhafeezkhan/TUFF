#!/usr/bin/env python3
import contextlib
import io
import itertools
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import calibrate_runtime as calibration
from calibrate_runtime import recommend


class CalibrationTests(unittest.TestCase):
    def rows(self, wall=8, **overrides):
        return [dict(preset=preset, repeat=repeat, status='finished', output='same',
                     prompt_tokens=128, cached_tokens=0, wall_seconds=10 if preset == 512 else wall,
                     prefill_seconds=4, decode_seconds=2, peak_memory_bytes=1000, **overrides)
                for repeat in range(1, 4) for preset in (512, 128)]

    def test_repeatable_gain_can_be_recommended_but_never_applied(self):
        result = recommend(self.rows(), 512, 3, .05)
        self.assertEqual(result['selected'], 128)
        self.assertFalse(result['applied'])

    def test_small_or_noisy_gain_keeps_baseline(self):
        self.assertEqual(recommend(self.rows(wall=9.8), 512, 3, .05)['selected'], 512)
        rows = self.rows()
        rows[1]['wall_seconds'] = 11
        self.assertEqual(recommend(rows, 512, 3, .05)['selected'], 512)

    def test_failures_output_mismatch_or_missing_evidence_keep_baseline(self):
        for field, value in [('status', 'failed'), ('output', 'different'),
                             ('prefill_seconds', None), ('wall_seconds', float('nan')),
                             ('prompt_tokens', 129), ('cached_tokens', 10),
                             ('decode_seconds', 3), ('peak_memory_bytes', 1100)]:
            rows = self.rows()
            for row in rows:
                if row['preset'] == 128:
                    row[field] = value
            self.assertEqual(recommend(rows, 512, 3, .05)['selected'], 512, field)

    def test_incomplete_pairs_or_insufficient_repetitions_keep_baseline(self):
        self.assertEqual(recommend(self.rows()[:-1], 512, 3, .05)['selected'], 512)
        self.assertEqual(recommend(self.rows(), 512, 2, .05)['selected'], 512)

    def test_cache_slot_identity_does_not_overwrite_equal_chunk_pairs(self):
        rows = [dict(preset=512, cache_slots=slots, repeat=repeat, status='finished',
                     output='same', prompt_tokens=128, cached_tokens=0,
                     wall_seconds=10 if slots == 16 else 8, prefill_seconds=4,
                     decode_seconds=2, peak_memory_bytes=1000)
                for repeat in range(1, 4) for slots in (16, 24)]
        result = recommend(rows, 512, 3, .05, baseline_slots=16)
        self.assertEqual(result['selected'], 512)
        self.assertEqual(result['selected_cache_slots'], 24)
        self.assertFalse(result['applied'])
        rows[1] = dict(rows[1], status='load-refused', error='memory busy')
        result = recommend(rows, 512, 3, .05, baseline_slots=16)
        self.assertEqual(result['selected_cache_slots'], 16)
        self.assertEqual(result['candidates'][0]['reason'], 'load or admission refused')

    def test_cache_sweep_is_opt_in_and_bounded_to_named_models(self):
        memory = 16 * 1024 ** 3
        self.assertIsNone(calibration.cache_sweep(None, ['minimax-m2.7'], 8192, 0))
        self.assertEqual(calibration.cache_sweep('24,16,24', ['gemma4'], 4096, memory), [24, 16])
        for value, models, context, size in [
            ('48', ['gemma4'], 4096, memory),
            ('16', ['minimax-m2.7'], 4096, memory),
            ('16', ['gemma4-e2b'], 4096, memory),
            ('16', ['gemma4'], 8192, memory),
            ('16', ['gemma4'], 4096, memory // 2),
            ('', ['gemma4'], 4096, memory),
        ]:
            with self.subTest(value=value, models=models, context=context, size=size):
                with self.assertRaises(ValueError):
                    calibration.cache_sweep(value, models, context, size)

    def run_fake_sweep(self, refuse_candidate=False, refuse_chunk=None, fail_warmup=False):
        instances = []
        active = set()
        test = self

        class FakeService:
            def __init__(self, binary, environment, log):
                test.assertFalse(active, 'model sessions must never overlap')
                test.assertEqual(environment['TUFF_CONVERSATION_CACHE_MB'], '0')
                self.slots = None
                self.generations = 0
                self.loads = []
                self.runtime = None
                instances.append(self)
                active.add(self)

            def request(self, command, timeout):
                if 'load' in command:
                    self.runtime = dict(command['load']['_0']['runtimeOptions'])
                    self.loads.append(self.runtime)
                    self.slots = self.runtime['expertCacheSlots']
                    if (refuse_candidate and self.slots == 24) or self.runtime['prefillChunkTokens'] == refuse_chunk:
                        return [dict(kind='failed', error='memory admission refused')]
                    return [dict(kind='ready')]
                request = command['generate']['_0']
                test.assertEqual(request['runtimeOptions'], self.runtime)
                test.assertEqual(request['history'], [])
                self.generations += 1
                if fail_warmup:
                    return [dict(kind='failed', error='generation fixture failure')]
                return [dict(kind='snapshot', textDelta='same'), dict(
                    kind='finished', promptTokenCount=128, cachedPromptTokens=0,
                    prefillSeconds=4, decodeSeconds=2, tokenCount=64,
                    tokensPerSecond=32, peakMemoryBytes=1000, currentMemoryBytes=1000)]

            def close(self):
                active.remove(self)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service = root / 'TUFFDecodeService'
            service.write_text('fixture')
            model = root / 'models/gemma4.gturbo'
            model.mkdir(parents=True)
            (model / 'manifest.json').write_text('{}')
            output = root / 'output'
            argv = ['calibrate_runtime.py', '--service', str(service),
                    '--model-root', str(root / 'models'), '--models', 'gemma4',
                    '--chunks', '128', '--cache-slots', '24', '--shapes', 'short',
                    '--repeat', '3', '--output', str(output)]
            with patch('sys.argv', argv), patch.object(calibration, 'Service', FakeService), \
                 patch.object(calibration, 'require_idle_inference'), \
                 patch.object(calibration, 'source_identity', return_value={}), \
                 patch.object(calibration, 'machine_state', return_value={}), \
                 patch.object(calibration.subprocess, 'check_output', return_value=str(16 * 1024 ** 3)), \
                 patch.object(calibration.time, 'monotonic', side_effect=itertools.count()), \
                 contextlib.redirect_stdout(io.StringIO()):
                try:
                    status = calibration.main()
                finally:
                    self.assertFalse(active, 'failed loads and warmups must close their service')
            rows = json.loads((output / 'rows.json').read_text())
            result = json.loads((output / 'recommendations.json').read_text())
        self.assertFalse(active)
        return status, instances, rows, result

    def test_sweep_loads_every_chunk_and_slot_exactly_before_generation(self):
        status, instances, rows, result = self.run_fake_sweep()
        self.assertEqual(status, 0)
        self.assertEqual([s.slots for s in instances], [16, 24, 24, 16, 16, 24])
        self.assertTrue(all(s.generations == 4 for s in instances))
        self.assertEqual([[r['prefillChunkTokens'] for r in s.loads] for s in instances],
                         [[512, 128], [512, 128], [128, 512], [128, 512], [512, 128], [512, 128]])
        self.assertEqual(len(rows), 12)
        self.assertEqual({(r['preset'], r['cache_slots']) for r in rows},
                         {(512, 16), (128, 16), (512, 24), (128, 24)})
        self.assertFalse(result['applied'])

    def test_candidate_admission_refusal_is_recorded_and_never_recommended(self):
        status, instances, rows, result = self.run_fake_sweep(refuse_candidate=True)
        self.assertEqual(status, 1)
        self.assertTrue(all(s.generations == 0 for s in instances if s.slots == 24))
        self.assertEqual(sum(r['status'] == 'load-refused' for r in rows), 6)
        selected = result['recommendations'][0]
        self.assertEqual(selected['selected_cache_slots'], 16)
        self.assertEqual(selected['runtime_options']['expertCacheSlots'], 16)


    def test_candidate_chunk_load_refusal_is_recorded_and_never_recommended(self):
        status, instances, rows, result = self.run_fake_sweep(refuse_chunk=128)
        self.assertEqual(status, 1)
        self.assertEqual(sum(r['status'] == 'load-refused' for r in rows), 6)
        self.assertTrue(all(s.generations == 2 for s in instances))
        self.assertEqual(result['recommendations'][0]['selected'], 512)

    def test_failed_warmup_closes_the_loaded_service(self):
        with self.assertRaisesRegex(RuntimeError, 'warmup failed'):
            self.run_fake_sweep(fail_warmup=True)


if __name__ == '__main__':
    unittest.main()
