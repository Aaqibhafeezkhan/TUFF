#!/usr/bin/env python3
"""Validate bounded Messages and Responses APIs with installed models and synthetic tool results. Never launches an app in /Applications."""
import argparse
import copy
import hashlib
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

MODELS = {'gemma4': 'gemma-4-26b-a4b-it', 'qwen38-flash-next': 'qwen3.8-flash-next'}
SCHEMA = {'type': 'object', 'properties': {'query': {'type': 'string'}}, 'required': ['query']}
QUESTION = 'Use web_search to find the height of the Hallgrimskirkja tower in Reykjavik. For this response, emit only the tool call, with no text before or after it.'
RESULT = '[1] Hallgrimskirkja: The church tower rises 74.5 metres. Source: https://visitreykjavik.example/hallgrimskirkja'
SYSTEM = 'Be concise. Use the provided search tool when asked. After its result, answer directly using the result and cite [1]. Do not search again.'


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def frames_from(raw):
    text = raw.decode('utf-8').replace('\r\n', '\n')
    frames = []
    for block in text.split('\n\n'):
        event, data = None, []
        for line in block.splitlines():
            if line.startswith('event:'): event = line[6:].strip()
            elif line.startswith('data:'): data.append(line[5:].lstrip())
        if not data: continue
        obj = json.loads('\n'.join(data))
        assert event == obj.get('type'), (event, obj)
        assert event != 'error', obj
        frames.append(obj)
    assert frames, 'No SSE frames'
    return frames


def decode_result(route, stream, raw):
    if not stream:
        obj = json.loads(raw)
        assert obj.get('type') != 'error' and obj.get('error') is None, obj
        if route == 'messages':
            assert obj['type'] == 'message' and obj['role'] == 'assistant', obj
            assert obj['stop_reason'] in ['end_turn', 'tool_use'], obj
        else:
            assert obj['object'] == 'response' and obj['status'] == 'completed', obj
        return obj, []
    frames = frames_from(raw)
    if route == 'responses':
        assert [f['sequence_number'] for f in frames] == list(range(len(frames))), frames
        assert frames[0]['type'] == 'response.created' and frames[-1]['type'] == 'response.completed', frames
        obj = frames[-1]['response']
        completed = [f['item'] for f in frames if f['type'] == 'response.output_item.done']
        assert completed == obj['output'], (completed, obj)
        for item in completed:
            if item['type'] == 'function_call':
                deltas = ''.join(f['delta'] for f in frames if f['type'] == 'response.function_call_arguments.delta' and f['item_id'] == item['id'])
                assert deltas == item['arguments'], item
            elif item['type'] == 'message':
                deltas = ''.join(f['delta'] for f in frames if f['type'] == 'response.output_text.delta' and f['item_id'] == item['id'])
                assert deltas == ''.join(p['text'] for p in item['content']), item
        return obj, frames
    assert frames[0]['type'] == 'message_start' and frames[-1]['type'] == 'message_stop', frames
    obj = copy.deepcopy(frames[0]['message'])
    content, partial, stopped = {}, {}, set()
    for frame in frames:
        kind = frame['type']
        if kind == 'content_block_start':
            index = frame['index']; assert index not in content
            content[index] = copy.deepcopy(frame['content_block'])
        elif kind == 'content_block_delta':
            index = frame['index']; delta = frame['delta']; assert index in content and index not in stopped
            if delta['type'] == 'text_delta': content[index]['text'] += delta['text']
            elif delta['type'] == 'input_json_delta': partial[index] = partial.get(index, '') + delta['partial_json']
            else: raise AssertionError(delta)
        elif kind == 'content_block_stop':
            index = frame['index']; assert index in content and index not in stopped
            stopped.add(index)
            if index in partial: content[index]['input'] = json.loads(partial[index])
        elif kind == 'message_delta':
            obj.update(frame['delta']); obj['usage'] = frame['usage']
            obj['tuff_timings_seconds'] = frame.get('tuff_timings_seconds', {})
    assert stopped == set(content) and sorted(content) == list(range(len(content)))
    obj['content'] = [content[i] for i in sorted(content)]
    assert obj['stop_reason'] in ['end_turn', 'tool_use'], obj
    return obj, frames


def text_and_calls(route, obj):
    if route == 'messages':
        return ''.join(b['text'] for b in obj['content'] if b['type'] == 'text'), [b for b in obj['content'] if b['type'] == 'tool_use']
    return ''.join(p['text'] for item in obj['output'] if item['type'] == 'message' for p in item['content']), [b for b in obj['output'] if b['type'] == 'function_call']


def payload(route, model, stream, tool, maximum):
    question = QUESTION if tool else 'Reply with a short greeting.'
    value = {'model': model, 'temperature': 0, 'stream': stream}
    if route == 'messages':
        value.update(system=SYSTEM, max_tokens=maximum, messages=[{'role': 'user', 'content': question}], thinking={'type': 'disabled'})
        if tool: value['tools'] = [{'name': 'web_search', 'description': 'Search the web for factual information.', 'input_schema': SCHEMA}]
    else:
        value.update(instructions=SYSTEM, max_output_tokens=maximum, store=False, input=[{'role': 'user', 'content': question}])
        if tool: value['tools'] = [{'type': 'function', 'name': 'web_search', 'description': 'Search the web for factual information.', 'parameters': SCHEMA}]
    return value


def followup(route, request, response, calls):
    value = copy.deepcopy(request)
    if route == 'messages':
        value['messages'].append({'role': 'assistant', 'content': response['content']})
        value['messages'].append({'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': call['id'], 'content': RESULT} for call in calls] + [{'type': 'text', 'text': 'Now answer the original question directly using the result and cite [1]. Do not call a tool again.'}]})
    else:
        value['input'].extend(response['output'])
        value['input'].extend({'type': 'function_call_output', 'call_id': call['call_id'], 'output': RESULT} for call in calls)
        value['input'].append({'role': 'user', 'content': 'Now answer the original question directly using the result and cite [1]. Do not call a tool again.'})
    return value


class Harness:
    def __init__(self, base, output, timeout):
        self.base, self.output, self.timeout, self.rows = base, output, timeout, []

    def request(self, route, value, label):
        body = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
        (self.output / (label + '.request.json')).write_bytes(body)
        req = urllib.request.Request(self.base + '/v1/' + route, body, {'Content-Type': 'application/json'}, method='POST')
        started = time.monotonic()
        try:
            response = urllib.request.urlopen(req, timeout=self.timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            first = time.monotonic()
            raw = response.read()
            row = {'label': label, 'model': value['model'], 'route': route, 'stream': value['stream'], 'status': response.status,
                   'headers_seconds': first - started, 'wall_seconds': time.monotonic() - started,
                   'response_headers': dict(response.headers), 'request_sha256': hashlib.sha256(body).hexdigest()}
        (self.output / (label + '.response.txt')).write_bytes(raw)
        self.rows.append(row); save(self.output / 'rows.json', self.rows)
        try:
            assert row['status'] == 200, raw.decode(errors='replace')
            content_type = row['response_headers'].get('content-type', row['response_headers'].get('Content-Type', ''))
            assert ('text/event-stream' in content_type) == value['stream'], content_type
            obj, frames = decode_result(route, value['stream'], raw)
            save(self.output / (label + '.decoded.json'), {'response': obj, 'frames': frames})
            row['usage'] = obj.get('usage'); row['tuff_timings_seconds'] = obj.get('tuff_timings_seconds')
            assert isinstance(row['usage'], dict), obj
            assert isinstance(row['tuff_timings_seconds'], dict) and 'prefill' in row['tuff_timings_seconds'] and 'decode' in row['tuff_timings_seconds'], obj
            row['wire_passed'] = True
            return obj
        except Exception as error:
            row.update(wire_passed=False, error=repr(error)); raise
        finally:
            save(self.output / 'rows.json', self.rows)
            print(label, json.dumps(row), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', required=True, type=Path, help='Packaged TUFFServer link outside /Applications')
    parser.add_argument('--models-root', required=True, type=Path, help='Directory containing installed model packs')
    parser.add_argument('--models', default='gemma4,qwen38-flash-next', help='Comma-separated installed models: gemma4,qwen38-flash-next')
    parser.add_argument('--output', required=True, type=Path, help='New directory for synthetic requests, responses and validation evidence')
    parser.add_argument('--timeout', type=int, default=1200)
    parser.add_argument('--max-new', type=int, default=128)
    args = parser.parse_args()
    server = args.server.absolute()
    assert server.name == 'TUFFServer' and server.is_file(), 'Use the packaged TUFFServer link'
    assert not server.resolve().is_relative_to('/Applications'), 'Personal installed applications are prohibited'
    models = args.models.split(','); assert all(m in MODELS for m in models)
    require_idle_inference()
    args.output.mkdir(parents=True, exist_ok=False)
    home = args.output / 'isolated-home'; home.mkdir()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    environment = os.environ.copy()
    environment.update(CFFIXED_USER_HOME=str(home.absolute()), HOME=str(home.absolute()), TUFF_LOG_REQUEST_DIAGNOSTICS='1')
    command = [str(server), '--models-root', str(args.models_root.resolve()), '--port', str(port), '--unload-after', '300', '--queue-limit', '1']
    save(args.output / 'identity.json', {'server': str(server), 'resolved_executable': str(server.resolve()), 'server_sha256': hashlib.sha256(server.read_bytes()).hexdigest(),
        'source': source_identity(), 'machine_before': machine_state(), 'command': command, 'models': models, 'model_roots': str(args.models_root.resolve())})
    failures = []
    log = (args.output / 'server.log').open('wb')
    proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=environment)
    harness = Harness(f'http://127.0.0.1:{port}', args.output, args.timeout)
    try:
        for _ in range(200):
            assert proc.poll() is None, 'Server exited; inspect server.log'
            try:
                with urllib.request.urlopen(harness.base + '/health', timeout=1) as response:
                    if response.status == 200: break
            except (urllib.error.URLError, TimeoutError): time.sleep(.1)
        else: raise RuntimeError('Server health timeout')
        with urllib.request.urlopen(harness.base + '/v1/models', timeout=5) as response:
            save(args.output / 'models.json', json.load(response))
        for model in models:
            for route in ['messages', 'responses']:
                for stream in [False, True]:
                    prefix = f'{model}-{route}-' + ('sse' if stream else 'json')
                    for tool in [False, True]:
                        name = prefix + ('-tool' if tool else '-text')
                        try:
                            request = payload(route, MODELS[model], stream, tool, args.max_new)
                            obj = harness.request(route, request, name)
                            text, calls = text_and_calls(route, obj)
                            if not tool:
                                assert text.strip() and not calls, obj
                            else:
                                assert calls, 'No tool call: ' + repr(obj)
                                assert len({c.get('id', c.get('call_id')) for c in calls}) == len(calls), calls
                                for call in calls:
                                    assert call['name'] == 'web_search', call
                                    arguments = call['input'] if route == 'messages' else json.loads(call['arguments'])
                                    assert isinstance(arguments.get('query'), str) and arguments['query'].strip(), call
                                second = harness.request(route, followup(route, request, obj, calls), name + '-result')
                                answer, further = text_and_calls(route, second)
                                assert not further and '74.5' in answer and '[1]' in answer, second
                            save(args.output / (name + '.passed.json'), {'passed': True})
                        except Exception as error:
                            failures.append({'case': name, 'error': repr(error)})
                            save(args.output / 'failures.json', failures)
                            print('FAIL', name, repr(error), flush=True)
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try: proc.wait(timeout=30)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=10)
        log.close()
        save(args.output / 'summary.json', {'requests': len(harness.rows), 'failures': failures, 'spawned_server_exit': proc.returncode,
                                         'machine_after': machine_state()})
    return 1 if failures else 0

if __name__ == '__main__':
    raise SystemExit(main())
