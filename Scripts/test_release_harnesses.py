#!/usr/bin/env python3
import io
import contextlib
import sys
import json
import os
import subprocess
from pathlib import Path
import struct
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import benchmark_inference as bench
import validate_release_interfaces as interfaces
import benchmark_reporting as reporting
import validate_release_models as release_models


class HarnessTests(unittest.TestCase):
    def test_serial_runner_stops_when_preliminary_check_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'Scripts'
            scripts.mkdir()
            source = Path(__file__).resolve().parent / 'test.sh'
            (scripts / 'test.sh').write_text(source.read_text())
            tools = root / 'bin'
            tools.mkdir()
            for name, body in [('ruby', 'exit 17'),
                               ('swift', 'touch "$TUFF_UNEXPECTED_SWIFT"; exit 0')]:
                tool = tools / name
                tool.write_text('#!/bin/sh\n' + body + '\n')
                tool.chmod(0o755)
            marker = root / 'swift-ran'
            result = subprocess.run(['/bin/bash', str(scripts / 'test.sh')],
                                    env=dict(os.environ, PATH=str(tools) + ':/usr/bin:/bin',
                                             TUFF_UNEXPECTED_SWIFT=str(marker)),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 17, result.stderr)
            self.assertFalse(marker.exists())

    def test_targeted_model_rechecks_preserve_default_and_reject_silent_skips(self):
        models={'flash':{'path':'flash'},'gemma':{'path':'gemma'},'mini':{'path':'mini'}}
        self.assertEqual(release_models.selected_models(models,None),models)
        self.assertEqual(release_models.selected_models(models,'mini,flash'),
                         {'flash':{'path':'flash'},'mini':{'path':'mini'}})
        for selection in ['', 'unknown', 'flash,', 'flash,flash']:
            with self.assertRaises(ValueError): release_models.selected_models(models,selection)
    def test_app_smoke_requires_visible_answer_and_successful_terminal(self):
        events=[{'kind':'snapshot','thinkingDelta':'Paris'},
                {'kind':'snapshot','textDelta':'The capital is Pa'},
                {'kind':'snapshot','textDelta':'ris.'}]
        self.assertEqual(interfaces.app_answer(events),'The capital is Paris.')
        self.assertTrue(interfaces.app_passed({'kind':'finished','tokenCount':4},events,'PARIS'))
        self.assertFalse(interfaces.app_passed({'kind':'finished','tokenCount':4},events[:1],'Paris'))
        self.assertFalse(interfaces.app_passed({'kind':'failed','tokenCount':4},events,'Paris'))
        self.assertFalse(interfaces.app_passed({'kind':'finished','tokenCount':0},events,'Paris'))
    def test_app_latency_excludes_post_request_machine_probe(self):
        from unittest.mock import MagicMock
        clock=[0.0]
        def probe():
            clock[0]+=100
            return {}
        events=iter([{'kind':'ready'},{'kind':'finished','tokenCount':1}])
        def read(*unused):
            event=next(events)
            clock[0]+=1 if event['kind']=='ready' else 7
            return event
        with tempfile.TemporaryDirectory() as directory:
            args=SimpleNamespace(app=Path(directory)/'fixture.app',model_root=Path(directory),
                output=Path(directory),modes='greedy',shapes='short',repeat=1,max_new=4,timeout=60,lookahead=None)
            config={'path':'gemma4.gturbo','runtime':['--expert-cache-slots','16','--prefill','on','--prefill-chunk-tokens','512','--rdadvise','off'],
                    'sampling':['--temperature','0.2','--top-k','64','--top-p','0.95']}
            proc=MagicMock();proc.poll.return_value=0
            with patch.object(interfaces,'require_idle_inference'),patch.object(interfaces,'machine_state',side_effect=probe),patch.object(interfaces.time,'monotonic',side_effect=lambda:clock[0]),patch.object(interfaces.subprocess,'Popen',return_value=proc),patch.object(interfaces,'send_frame'),patch.object(interfaces,'read_frame',side_effect=read),patch.object(interfaces,'digest',return_value='fixture'),contextlib.redirect_stdout(io.StringIO()):
                rows=interfaces.service_run(args,'gemma4',config)
            self.assertEqual(rows[0]['wall_seconds'],7)
            self.assertEqual(rows[0]['load_seconds'],1)

    def test_server_latency_excludes_post_request_machine_probe(self):
        from unittest.mock import MagicMock
        clock=[0.0]
        def probe():
            clock[0]+=100
            return {}
        def response(url,*unused):
            if url.endswith('/health'): return {'status':'ok'}
            if url.endswith('/v1/models'): return {'data':[{'id':'fixture'}]}
            clock[0]+=7
            return {'choices':[{'message':{'content':'Paris.'}}]}
        with tempfile.TemporaryDirectory() as directory:
            args=SimpleNamespace(app=Path(directory)/'fixture.app',model_root=Path(directory),
                output=Path(directory),modes='sampled',timeout=60,lookahead=None)
            config={'path':'gemma4.gturbo','runtime':['--expert-cache-slots','16'],
                    'sampling':['--temperature','0.2','--top-k','64','--top-p','0.95']}
            proc=MagicMock();proc.poll.return_value=0
            with patch.object(interfaces,'require_idle_inference'),patch.object(interfaces,'machine_state',side_effect=probe),patch.object(interfaces.time,'monotonic',side_effect=lambda:clock[0]),patch.object(interfaces.subprocess,'Popen',return_value=proc),patch.object(interfaces,'get_json',side_effect=response),patch.object(interfaces,'digest',return_value='fixture'),contextlib.redirect_stdout(io.StringIO()):
                rows=interfaces.server_run(args,'gemma4',config)
            self.assertEqual(rows[0]['wall_seconds'],7)
            self.assertEqual(rows[0]['status'],'passed')
            # Routing on both 7.0.0 and later servers; catalog settings, not the app runtime flags.
            self.assertIn('--all-models',rows[0]['command'])
            self.assertNotIn('--expert-cache-slots',rows[0]['command'])

    def test_competing_process_guard_omits_arguments_and_preserves_other_processes(self):
        output = ' 11 /tmp/TUFF.app/Contents/Resources/bin/TUFFCLI\n 12 /usr/bin/python3\n 13 /tmp/TUFFEnginePackageTests.xctest\n'
        with patch.object(reporting.subprocess,'check_output',return_value=output):
            self.assertEqual(reporting.inference_processes(),
                             [dict(pid=11,executable='TUFFCLI'),dict(pid=13,executable='TUFFEnginePackageTests.xctest')])
            with self.assertRaises(RuntimeError): reporting.require_idle_inference()
        with patch.object(reporting.subprocess,'check_output',return_value=' 12 /usr/bin/python3\n'):
            reporting.require_idle_inference()

    def test_interrupted_measurement_reaps_its_own_process(self):
        from unittest.mock import MagicMock
        proc=MagicMock(pid=1234)
        proc.wait.side_effect=[KeyboardInterrupt,None]
        proc.poll.return_value=None
        with tempfile.TemporaryDirectory() as directory,patch.object(bench,'machine_state',return_value={}),patch.object(bench,'require_idle_inference'),patch.object(bench.subprocess,'Popen',return_value=proc),patch.object(bench.os,'killpg') as kill:
            with self.assertRaises(KeyboardInterrupt):
                bench.run(['fixture'],Path(directory)/'interrupted',2)
            kill.assert_called_once_with(1234,bench.signal.SIGTERM)
            self.assertEqual(proc.wait.call_count,2)

    def test_interface_options_cannot_silently_skip_validation(self):
        base=['validate_release_interfaces.py','--app','fixture.app','--model-root','models',
              '--output','output']
        for option,value in [('--interfaces','typo'),('--modes','typo'),('--shapes','typo'),
                             ('--repeat','0'),('--max-new','0'),('--timeout','0'),('--comparison-repeat','0'),
                             ('--comparison-lookahead','off'),('--comparison-small-block','off'),
                             ('--comparison-shared-overlap','off'),('--comparison-slots','16'),
                             ('--comparison-chunk','512'),('--slots','0'),('--chunk','0')]:
            with patch.object(sys,'argv',base+[option,value]),contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error: interfaces.main()
                self.assertEqual(error.exception.code,2)

    def test_warm_app_comparisons_alternate_whole_sessions_and_keep_outputs_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);apps=[]
            for name in ['reference','candidate']:
                app=(root/(name+'.app')).resolve();apps.append(app)
                bundle=app/'Contents/Resources/TUFF_TUFFEngine.bundle';bundle.mkdir(parents=True)
                (bundle/'logit.metal').write_text('kernel void fixture() {}')
            model=root/'models/gemma4.gturbo';model.mkdir(parents=True)
            (model/'manifest.json').write_text('{"modelID":"fixture","sourceSnapshotHash":"pinned"}')
            arguments=['validate_release_interfaces.py','--app',str(apps[1]),
                       '--comparison-app',str(apps[0]),'--model-root',str(root/'models'),
                       '--output',str(root/'output'),'--models','gemma4','--interfaces','app',
                       '--repeat','2','--comparison-repeat','3','--lookahead','off',
                       '--comparison-lookahead','on','--slots','32','--comparison-slots','16',
                       '--chunk','1024','--comparison-chunk','512']
            with patch.object(sys,'argv',arguments),patch.object(interfaces,'service_run',side_effect=lambda *args:[dict(status='passed')]) as run:
                self.assertEqual(interfaces.main(),0)
            self.assertEqual([call.args[0].app for call in run.call_args_list],
                             [apps[0],apps[1],apps[1],apps[0],apps[0],apps[1]])
            self.assertEqual(len({call.args[0].output for call in run.call_args_list}),6)
            self.assertTrue(all(call.args[0].repeat==2 for call in run.call_args_list))
            self.assertEqual([interfaces.environment_overrides(call.args[0]) for call in run.call_args_list],
                             [{'TUFF_EXPERT_LOOKAHEAD':x} for x in ['on','off','off','on','on','off']])
            self.assertEqual([call.args[2]['runtime'][1] for call in run.call_args_list],
                             ['16','32','32','16','16','32'])
            self.assertEqual([call.args[2]['runtime'][5] for call in run.call_args_list],
                             ['512','1024','1024','512','512','1024'])
            report=json.loads((root/'output/results.json').read_text())
            self.assertEqual([row['comparison_attempt'] for row in report['results']],[0,0,1,1,2,2])
            self.assertTrue(all(row['model_identity']['sourceSnapshotHash']=='pinned' for row in report['results']))

    def test_comparison_options_require_a_reference_and_positive_work(self):
        base=['benchmark_inference.py','--cli','fixture.app/TUFFCLI','--model-root','models',
              '--output','output']
        for option,value in [('--comparison-slots','16'),('--comparison-chunk','512'),
                             ('--comparison-lookahead','off'),('--comparison-small-block','off'),
                             ('--comparison-shared-overlap','off'),('--shapes','typo'),('--repeat','0'),
                             ('--max-new','0'),('--timeout','0'),('--slots','0'),('--chunk','0')]:
            with patch.object(sys,'argv',base+[option,value]),contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error: bench.main()
                self.assertEqual(error.exception.code,2)

    def test_interface_small_block_switch_reaches_the_service_environment(self):
        args=SimpleNamespace(lookahead=None,small_block='on')
        self.assertEqual(interfaces.environment_overrides(args),{'TUFF_SMALL_BLOCK_PREFILL':'on'})
        self.assertEqual(interfaces.environment_overrides(SimpleNamespace(lookahead='off')),
                         {'TUFF_EXPERT_LOOKAHEAD':'off'})
        self.assertEqual(interfaces.environment_overrides(SimpleNamespace(lookahead=None,shared_overlap='on')),
                         {'TUFF_SHARED_EXPERT_OVERLAP':'on'})

    def test_small_block_comparison_changes_only_the_named_switch(self):
        args=SimpleNamespace(lookahead='off',comparison_lookahead=None,
                             small_block='on',comparison_small_block='off')
        self.assertEqual(bench.environment_overrides(args,'candidate'),
                         {'TUFF_EXPERT_LOOKAHEAD':'off','TUFF_SMALL_BLOCK_PREFILL':'on'})
        self.assertEqual(bench.environment_overrides(args,'reference'),
                         {'TUFF_EXPERT_LOOKAHEAD':'off','TUFF_SMALL_BLOCK_PREFILL':'off'})
        unset=SimpleNamespace(lookahead=None,comparison_lookahead=None,
                              small_block=None,comparison_small_block=None)
        self.assertEqual(bench.environment_overrides(unset,'primary'),{})

    def test_shared_overlap_comparison_changes_only_the_named_switch(self):
        args=SimpleNamespace(lookahead=None,comparison_lookahead=None,
                             small_block=None,comparison_small_block=None,
                             shared_overlap='on',comparison_shared_overlap='off')
        self.assertEqual(bench.environment_overrides(args,'candidate'),
                         {'TUFF_SHARED_EXPERT_OVERLAP':'on'})
        self.assertEqual(bench.environment_overrides(args,'reference'),
                         {'TUFF_SHARED_EXPERT_OVERLAP':'off'})
        inherited=SimpleNamespace(lookahead=None,comparison_lookahead=None,
                                  small_block=None,comparison_small_block=None,
                                  shared_overlap='on',comparison_shared_overlap=None)
        self.assertEqual(bench.environment_overrides(inherited,'reference'),
                         {'TUFF_SHARED_EXPERT_OVERLAP':'on'})

    def test_workloads_are_stable_distinct_and_do_not_repeat_calibration_text(self):
        self.assertEqual(bench.prompt('long'),bench.prompt('long'))
        self.assertNotEqual(bench.prompt('short'),bench.prompt('long'))
        self.assertEqual(bench.prompt('long').count('Day '),28)
        self.assertIn('Day 28:',bench.prompt('long'))

    def test_frames_are_little_endian_and_preserve_unicode(self):
        pipe=io.BytesIO();interfaces.send_frame(pipe,{'prompt':'café 雨'})
        data=pipe.getvalue();count=struct.unpack('<I',data[:4])[0]
        self.assertEqual(count,len(data)-4)
        self.assertEqual(json.loads(data[4:]),{'prompt':'café 雨'})
        with patch.object(interfaces,'MAX_FRAME',2):
            with self.assertRaises(ValueError): interfaces.send_frame(io.BytesIO(),{'prompt':'x'})

    def test_reader_handles_partial_reads_eof_and_oversized_input(self):
        value={'kind':'finished','tokenCount':3}
        data=json.dumps(value).encode();chunks=[struct.pack('<I',len(data)),data[:3],data[3:]]
        with io.FileIO('/dev/null') as pipe:
            with patch.object(interfaces.select,'select',return_value=([1],[],[])),patch.object(interfaces.os,'read',side_effect=chunks):
                self.assertEqual(interfaces.read_frame(pipe,time.monotonic()+1),value)
            with patch.object(interfaces.select,'select',return_value=([1],[],[])),patch.object(interfaces.os,'read',return_value=b''):
                with self.assertRaises(EOFError): interfaces.read_frame(pipe,time.monotonic()+1)
            with patch.object(interfaces.select,'select',return_value=([1],[],[])),patch.object(interfaces.os,'read',return_value=struct.pack('<I',interfaces.MAX_FRAME+1)):
                with self.assertRaises(ValueError): interfaces.read_frame(pipe,time.monotonic()+1)

    def test_shader_identity_is_independent_of_app_location(self):
        with tempfile.TemporaryDirectory() as directory:
            hashes=[]
            for name in ['reference.app','candidate.app']:
                app=Path(directory)/name
                bundle=app/'Contents/Resources/TUFF_TUFFEngine.bundle';bundle.mkdir(parents=True)
                (bundle/'logit.metal').write_text('kernel void reference() {}')
                hashes.append(bench.shader_digest(app/'Contents/Resources/bin/TUFFCLI'))
            self.assertEqual(hashes[0],hashes[1])
            (bundle/'logit.metal').write_text('kernel void changed() {}')
            self.assertNotEqual(hashes[0],bench.shader_digest(app/'Contents/Resources/bin/TUFFCLI'))

    def test_paired_order_resume_and_changed_binary_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);binaries=[]
            for name in ['reference','candidate']:
                app=root/(name+'.app');binary=app/'Contents/Resources/bin/TUFFCLI'
                binary.parent.mkdir(parents=True);binary.write_text(name)
                bundle=app/'Contents/Resources/TUFF_TUFFEngine.bundle';bundle.mkdir()
                (bundle/'logit.metal').write_text('kernel void fixture() {}')
                binaries.append(binary)
            model=root/'models/gemma4.gturbo';model.mkdir(parents=True)
            (model/'manifest.json').write_text('{"modelID":"fixture"}')
            arguments=['benchmark_inference.py','--cli',str(binaries[1]),'--comparison-cli',str(binaries[0]),
                '--model-root',str(root/'models'),'--output',str(root/'output'),'--models','gemma4',
                '--shapes','short','--modes','greedy','--repeat','2',
                '--slots','32','--comparison-slots','16','--chunk','1024','--comparison-chunk','512']
            with patch.object(sys,'argv',arguments),patch.object(bench,'run',side_effect=lambda *args:dict(status='passed',prefill_seconds=1,tps=2)) as run,contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(bench.main(),0)
                self.assertEqual(bench.main(),0)
                self.assertEqual(run.call_count,4)
                report=json.loads((root/'output/results.json').read_text())
                self.assertEqual([row['variant'] for row in report['results']],
                                 ['reference','candidate','candidate','reference'])
                self.assertIn('finished',report)
                for call,slots,chunk in zip(run.call_args_list,[16,32,32,16],[512,1024,1024,512]):
                    command=call.args[0]
                    self.assertEqual(command[command.index('--expert-cache-slots')+1],str(slots))
                    self.assertEqual(command[command.index('--prefill-chunk-tokens')+1],str(chunk))
                binaries[1].write_text('changed binary')
                with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit) as error:
                    bench.main()
                self.assertEqual(error.exception.code,2)

    def test_failed_measurements_keep_output_and_machine_observations(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix=Path(directory)/'minimax-m2.7-failed'
            with patch.object(bench,'machine_state',return_value={'memory_pressure':{'available':False}}),patch.object(bench,'require_idle_inference'):
                row=bench.run(['/bin/sh','-c','echo incomplete >&2; exit 3'],prefix,2)
            self.assertEqual(row['status'],'failed');self.assertEqual(row['exit_code'],3)
            self.assertTrue(Path(str(prefix)+'.stderr.txt').exists())
            self.assertEqual(row['machine_state_after']['memory_pressure']['available'],False)

    def test_success_requires_nonempty_generation_and_successful_reads(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(bench,'machine_state',return_value={}),patch.object(bench,'require_idle_inference'),patch.object(bench,'resolved_settings',return_value={'context':'4096'}):
            for tokens,failures,expected in [(0,0,'failed'),(3,1,'failed'),(3,0,'passed')]:
                footer=f'[stop=maxTokens prefill=36tok/1.00s new={tokens}tok decode=1.00s tok/s={tokens}.000]'
                with patch.object(Path,'read_text',return_value=footer),patch.object(bench,'expert_io',return_value={'demand':{'failures':failures}}):
                    row=bench.run(['/usr/bin/true'],Path(directory)/f'case-{tokens}-{failures}',2)
                self.assertEqual(row['status'],expected)

    def test_timed_out_process_is_reaped(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(bench,'machine_state',return_value={}),patch.object(bench,'require_idle_inference'):
            row=bench.run(['/bin/sleep','5'],Path(directory)/'timeout',0.02)
        self.assertEqual(row['status'],'failed');self.assertNotEqual(row['exit_code'],0)


if __name__=='__main__': unittest.main()
