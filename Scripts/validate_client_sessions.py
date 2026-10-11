#!/usr/bin/env python3
"""Validate what coding agents rely on with real installed models: how a turn
ends, continuing after tool results with reuse, and cancellation that leaves
saved state intact. Never launches an app in /Applications.

For each model, a session runs on a fresh server: a plain answer (finish
"stop", which for GPT-OSS ends on <|return|>), an answer cut off by the token
limit ("length"), a tool call ("tool_calls"), the tool result, and a
follow-up, which must both reuse saved state. A streamed follow-up is then
dropped mid-generation and the same request sent again. The same session
runs on a second fresh server without the dropped request, and the final
replies must match exactly. Usage counts are checked on every response.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))
from benchmark_reporting import machine_state, require_idle_inference
from benchmark_conversation_cache import source_identity

MODELS = {'gpt-oss-20b': {'reasoning_effort': 'low'}, 'qwen36': {}, 'gemma4': {}}
TOOLS = [{'type': 'function', 'function': {
    'name': 'read_file', 'description': 'Read a text file from the project.',
    'parameters': {'type': 'object', 'properties': {'path': {'type': 'string'}},
                   'required': ['path']}}}]
SYSTEM = 'You are a coding agent. Read files with read_file before answering. Answer in two sentences.'
FILE = 'import Foundation\nlet values = [3, 1, 2]\nprint(values.sorted())\n'


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


class Server:
    def __init__(self, binary, models_root, output, label, timeout):
        self.output, self.label, self.timeout = output, label, timeout
        home = output / f'{label}-home'
        home.mkdir()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        environment = os.environ.copy()
        environment.update(CFFIXED_USER_HOME=str(home.absolute()), HOME=str(home.absolute()))
        self.log = (output / f'{label}.server.log').open('wb')
        self.proc = subprocess.Popen(
            [str(binary), '--models-root', str(models_root), '--port', str(self.port),
             '--unload-after', '600', '--queue-limit', '2'],
            stdout=self.log, stderr=subprocess.STDOUT, env=environment)
        for _ in range(300):
            assert self.proc.poll() is None, f'{label} server exited; see its log'
            try:
                with urllib.request.urlopen(self.url('/health'), timeout=1):
                    return
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                time.sleep(.1)
        raise RuntimeError(f'{label} server did not answer /health')

    def url(self, path):
        return f'http://127.0.0.1:{self.port}{path}'

    def chat(self, body):
        request = urllib.request.Request(self.url('/v1/chat/completions'), json.dumps(body).encode(),
                                         {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            return json.load(response)

    def drop_stream(self, body, after_bytes=600):
        """Starts a streamed request and closes the connection mid-generation."""
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=self.timeout)
        connection.request('POST', '/v1/chat/completions', json.dumps(dict(body, stream=True)),
                           {'Content-Type': 'application/json'})
        response = connection.getresponse()
        assert response.status == 200, response.status
        received = b''
        while len(received) < after_bytes:
            chunk = response.read1(256)
            if not chunk:
                break
            received += chunk
        connection.close()
        return received

    def health(self):
        with urllib.request.urlopen(self.url('/health'), timeout=5) as response:
            return json.load(response)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        self.log.close()


def message(response):
    return response['choices'][0]['message']


def finish(response):
    return response['choices'][0]['finish_reason']


def check_usage(response):
    usage = response['usage']
    cached = (usage.get('prompt_tokens_details') or {}).get('cached_tokens', 0)
    assert usage['total_tokens'] == usage['prompt_tokens'] + usage['completion_tokens'], usage
    assert 0 <= cached <= usage['prompt_tokens'], usage
    assert usage['completion_tokens'] > 0, usage
    return cached


def reply(response):
    m = message(response)
    return {'content': m.get('content'),
            'calls': [c['function'] for c in m.get('tool_calls') or []]}


def session(server, model, extra, drop):
    """One agent session; returns the final reply and evidence."""
    base = dict(model=model, temperature=0, max_tokens=400, **extra)
    evidence = {}

    plain = server.chat(dict(base, messages=[{'role': 'user', 'content': 'What is 2 plus 2? Answer with the number.'}]))
    check_usage(plain)
    assert finish(plain) == 'stop' and (message(plain).get('content') or '').strip(), plain
    assert not message(plain).get('tool_calls'), plain
    evidence['plain'] = reply(plain)

    cut = server.chat(dict(base, max_tokens=24,
                           messages=[{'role': 'user', 'content': 'Write a long story about a lighthouse keeper.'}]))
    check_usage(cut)
    assert finish(cut) == 'length', cut

    history = [{'role': 'system', 'content': SYSTEM},
               {'role': 'user', 'content': 'What does main.swift print? Read it first.'}]
    first = server.chat(dict(base, tools=TOOLS, messages=history))
    check_usage(first)
    calls = message(first).get('tool_calls') or []
    assert finish(first) == 'tool_calls' and calls, first
    call = calls[0]
    assert call['function']['name'] == 'read_file', call
    json.loads(call['function']['arguments'])
    history += [{'role': 'assistant', 'content': message(first).get('content'), 'tool_calls': [call]},
                {'role': 'tool', 'tool_call_id': call['id'], 'content': FILE}]

    answered = server.chat(dict(base, tools=TOOLS, messages=history))
    evidence['tool_result_cached'] = check_usage(answered)
    assert evidence['tool_result_cached'] > 0, ('tool result did not reuse saved state', answered['usage'])
    assert finish(answered) == 'stop' and (message(answered).get('content') or '').strip(), answered
    history += [{'role': 'assistant', 'content': message(answered)['content']},
                {'role': 'user', 'content': 'Is the output sorted ascending or descending?'}]

    if drop:
        evidence['dropped_bytes'] = len(server.drop_stream(dict(base, tools=TOOLS, messages=history)))
        for _ in range(100):
            if server.health().get('active_requests') == 0:
                break
            time.sleep(.2)

    follow = server.chat(dict(base, tools=TOOLS, messages=history))
    evidence['follow_up_cached'] = check_usage(follow)
    assert evidence['follow_up_cached'] > 0, ('follow-up did not reuse saved state', follow['usage'])
    assert finish(follow) in ('stop', 'tool_calls'), follow
    evidence['final'] = reply(follow)
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--server', required=True, type=Path, help='Packaged TUFFServer outside /Applications')
    parser.add_argument('--models-root', required=True, type=Path)
    parser.add_argument('--models', default='gpt-oss-20b,qwen36,gemma4')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--allow-busy', action='store_true',
                        help='Run beside idle TUFF processes; a correctness check, not a timing')
    args = parser.parse_args()
    binary = args.server.absolute()
    assert binary.name == 'TUFFServer' and binary.is_file(), 'Use a TUFFServer binary'
    assert not binary.resolve().is_relative_to('/Applications'), 'Personal installed applications are prohibited'
    models = args.models.split(',')
    assert all(m in MODELS for m in models), models
    if not args.allow_busy:
        require_idle_inference()
    args.output.mkdir(parents=True, exist_ok=False)
    save(args.output / 'identity.json', {'server': str(binary), 'source': source_identity(),
                                         'machine_before': machine_state(), 'models': models})
    failures, results = [], {}
    for model in models:
        runs = {}
        for label, drop in (('dropped', True), ('uninterrupted', False)):
            server = Server(binary, args.models_root.resolve(), args.output, f'{model}-{label}', args.timeout)
            try:
                runs[label] = session(server, model, MODELS[model], drop)
                print(model, label, 'tool result cached', runs[label]['tool_result_cached'],
                      'follow-up cached', runs[label]['follow_up_cached'], flush=True)
            except Exception as error:
                failures.append({'model': model, 'run': label, 'error': repr(error)})
                print('FAIL', model, label, repr(error), flush=True)
            finally:
                server.stop()
        if len(runs) == 2:
            same = runs['dropped']['final'] == runs['uninterrupted']['final']
            print(model, 'reply after a dropped request matches:', same, flush=True)
            if not same:
                failures.append({'model': model, 'error': 'reply after a dropped request differs',
                                 'dropped': runs['dropped']['final'],
                                 'uninterrupted': runs['uninterrupted']['final']})
        results[model] = runs
    save(args.output / 'results.json', results)
    save(args.output / 'summary.json', {'failures': failures, 'machine_after': machine_state()})
    print(json.dumps({'models': models, 'failures': len(failures)}))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
