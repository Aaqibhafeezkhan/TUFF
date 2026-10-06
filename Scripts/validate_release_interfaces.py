#!/usr/bin/env python3
"""Exercise packaged app IPC and loopback HTTP sequentially, without launching the GUI."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import time
import urllib.request
import uuid
from benchmark_inference import digest, prompt, shader_digest, sys_exit_signal
from benchmark_reporting import machine_state, require_idle_inference

ROOT = Path(__file__).resolve().parents[1]
MAX_FRAME = 4 * 1024 * 1024


def environment_overrides(args):
    environment = {}
    if args.lookahead:
        environment['TUFF_EXPERT_LOOKAHEAD'] = args.lookahead
    if getattr(args, 'small_block', None):
        environment['TUFF_SMALL_BLOCK_PREFILL'] = args.small_block
    if getattr(args, 'shared_overlap', None):
        environment['TUFF_SHARED_EXPERT_OVERLAP'] = args.shared_overlap
    return environment


def app_answer(events):
    return ''.join(event.get('textDelta') or '' for event in events if event['kind']=='snapshot')


def app_passed(event, events, required_word=None):
    return (event['kind']=='finished' and event.get('tokenCount',0)>0
            and (not required_word or required_word.casefold() in app_answer(events).casefold()))


def send_frame(pipe, value):
    payload = json.dumps(value).encode()
    if len(payload) > MAX_FRAME:
        raise ValueError('oversized frame')
    pipe.write(struct.pack('<I', len(payload)) + payload)
    pipe.flush()


def read_exact(pipe, count, deadline):
    result = bytearray()
    while len(result) < count:
        remaining = deadline-time.monotonic()
        if remaining <= 0 or not select.select([pipe], [], [], remaining)[0]:
            raise TimeoutError('decode service response timeout')
        chunk = os.read(pipe.fileno(), count-len(result))
        if not chunk:
            raise EOFError('decode service closed the response pipe')
        result.extend(chunk)
    return result


def read_frame(pipe, deadline):
    count = struct.unpack('<I', read_exact(pipe, 4, deadline))[0]
    if count > MAX_FRAME:
        raise ValueError('oversized response')
    return json.loads(read_exact(pipe, count, deadline))


def stop(proc):
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()


def service_run(args, model, config):
    options = dict(expertCacheSlots=int(config['runtime'][1]), expertCachePolicy='lfu',
                   prefillEnabled=config['runtime'][3]=='on', prefillChunkTokens=int(config['runtime'][5]),
                   rdadvisePolicy=config['runtime'][7], modelVerification='trusted-install')
    binary = args.app/'Contents/MacOS/TUFFDecodeService'
    rows = []
    for mode in args.modes.split(','):
        require_idle_inference()
        log = args.output/f'app-{model}-{mode}.stderr.txt'
        with log.open('w') as stderr:
            proc = subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                                    stderr=stderr,bufsize=0,start_new_session=True,
                                    env=dict(os.environ,**environment_overrides(args)))
            try:
                load = dict(modelPath=str(args.model_root/Path(config['path']).name),maxContextTokens=4096,
                            runtimeOptions=options,forceLogitsHead=mode=='sampled',requestID=str(uuid.uuid4()))
                before = machine_state()
                start = time.monotonic()
                send_frame(proc.stdin, {'load':{'_0':load}})
                loaded = read_frame(proc.stdout,time.monotonic()+args.timeout)
                if loaded['kind'] != 'ready':
                    raise RuntimeError(loaded)
                load_seconds = time.monotonic()-start
                request_index = 0
                sampling = config['sampling']
                for shape in args.shapes.split(','):
                    for attempt in range(args.repeat):
                        request = dict(prompt=getattr(args,'prompt',None) or ('Plan A: ' if attempt%2==0 else 'Plan B: ')+prompt(shape),history=[],
                            maxNewTokens=args.max_new,maxContextTokens=4096,reasoning='off',preserveThinking=False,
                            temperature=0 if mode=='greedy' else float(sampling[sampling.index('--temperature')+1]),
                            topK=int(sampling[sampling.index('--top-k')+1]) or None,
                            topP=float(sampling[sampling.index('--top-p')+1]),repetitionPenalty=1,seed=20260721,
                            runtimeOptions=options,generationID=str(uuid.uuid4()))
                        if model.startswith('gpt-oss'):
                            request['reasoningEffort']='low'
                        if model=='minimax-m2.7':
                            request['reasoning']='on'
                        state = machine_state()
                        started = time.monotonic()
                        send_frame(proc.stdin,{'generate':{'_0':request}})
                        events = []
                        deadline = time.monotonic()+args.timeout
                        while True:
                            event = read_frame(proc.stdout,deadline); events.append(event)
                            if event['kind'] in ('finished','failed','cancelled'):
                                break
                        wall_seconds = time.monotonic()-started
                        row = dict(interface='app-service',model=model,mode=mode,shape=shape,attempt=attempt,
                            cache_state='cold runner' if request_index==0 else 'warm expert slots; unrelated prompt resets KV',
                            binary_sha256=digest(binary),load=load,request=request,load_seconds=load_seconds,
                            environment_overrides=environment_overrides(args),
                            load_machine_state=before,machine_state_before=state,machine_state_after=machine_state(),
                            wall_seconds=wall_seconds,events=events,answer=app_answer(events),
                            status='passed' if app_passed(event,events,getattr(args,'required_word',None)) else 'failed')
                        rows.append(row)
                        request_index += 1
                        (args.output/f'app-{model}-{mode}-{shape}-{attempt+1}.json').write_text(json.dumps(row,indent=2))
                        print(f"app {model} {mode} {shape} {attempt+1}: {row['status']}, TPS={event.get('tokensPerSecond', 'unavailable')}",flush=True)
                send_frame(proc.stdin,{'shutdown':{}})
                proc.wait(timeout=15)
            finally:
                stop(proc)
    return rows


def get_json(url, data=None, timeout=10):
    request = urllib.request.Request(url,data=json.dumps(data).encode() if data is not None else None,
                                     headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=timeout) as response:
        return json.loads(response.read())


def server_run(args, model, config):
    require_idle_inference()
    binary = args.app/'Contents/Resources/bin/TUFFServer'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
    # The server routes by request and runs each model with its catalog
    # context, cache and prefill settings, so runtime overrides do not apply.
    # --all-models selects routing on a 7.0.0 reference and is a no-op later.
    command = [str(binary),'--all-models','--models-root',str(args.model_root),'--port',str(port),
               '--default-model',model]
    rows=[]
    with (args.output/f'server-{model}.stdout.txt').open('w') as stdout, (args.output/f'server-{model}.stderr.txt').open('w') as stderr:
        proc = subprocess.Popen(command,stdout=stdout,stderr=stderr,start_new_session=True,
                                env=dict(os.environ,**environment_overrides(args)))
        base=f'http://127.0.0.1:{port}'
        try:
            deadline=time.monotonic()+args.timeout
            while True:
                try:
                    health=get_json(base+'/health'); break
                except (OSError,ValueError):
                    if proc.poll() is not None or time.monotonic()>deadline:
                        raise RuntimeError('server failed to start')
                    time.sleep(0.25)
            models=get_json(base+'/v1/models'); model_id=model
            sampling=config['sampling']
            for mode in args.modes.split(','):
                request=dict(model=model_id,messages=[dict(role='user',content=getattr(args,'prompt',None) or 'What is the capital of France? Answer in one short sentence.')],
                    max_tokens=256 if model=='minimax-m2.7' else 64,temperature=0 if mode=='greedy' else float(sampling[1]),
                    top_k=int(sampling[3]),top_p=float(sampling[5]),seed=20260721,stream=False)
                if model.startswith('gpt-oss'):
                    request['reasoning_effort']='low'
                elif model != 'minimax-m2.7':
                    request['enable_thinking']=False
                if request['top_k']==0:
                    del request['top_k']
                before=machine_state(); start=time.monotonic()
                response=get_json(base+'/v1/chat/completions',request,args.timeout)
                wall_seconds=time.monotonic()-start
                message=response['choices'][0]['message']
                answer=message.get('content') or ''
                row=dict(interface='http-server',model=model,mode=mode,command=command,binary_sha256=digest(binary),
                         environment_overrides=environment_overrides(args),
                         health=health,models=models,request=request,response=response,
                         machine_state_before=before,machine_state_after=machine_state(),wall_seconds=wall_seconds,
                         status='passed' if (getattr(args,'required_word',None) or 'Paris').casefold() in answer.casefold() else 'failed')
                rows.append(row)
                (args.output/f'server-{model}-{mode}.json').write_text(json.dumps(row,indent=2))
                print(f"server {model} {mode}: {row['status']}",flush=True)
        finally:
            stop(proc)
    return rows


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app',type=Path,required=True);p.add_argument('--model-root',type=Path,required=True)
    p.add_argument('--comparison-app',type=Path,help='Alternate complete warm-cache sessions with this reference app')
    p.add_argument('--comparison-repeat',type=int,default=3)
    p.add_argument('--lookahead',choices=['on','off'])
    p.add_argument('--comparison-lookahead',choices=['on','off'])
    p.add_argument('--small-block',choices=['on','off'],help='TUFF_SMALL_BLOCK_PREFILL for the candidate (default: unset, which is off)')
    p.add_argument('--comparison-small-block',choices=['on','off'])
    p.add_argument('--shared-overlap',choices=['on','off'],help='TUFF_SHARED_EXPERT_OVERLAP for the candidate (default: unset, which is off)')
    p.add_argument('--comparison-shared-overlap',choices=['on','off'])
    p.add_argument('--slots',type=int,help='App-service expert-cache slots; the server uses catalog settings');p.add_argument('--comparison-slots',type=int)
    p.add_argument('--chunk',type=int,help='App-service prefill chunk; the server uses catalog settings');p.add_argument('--comparison-chunk',type=int)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--models',default='qwen38-flash-next,gemma4')
    p.add_argument('--interfaces',default='app,server');p.add_argument('--modes',default='greedy,sampled')
    p.add_argument('--shapes',default='short');p.add_argument('--repeat',type=int,default=3)
    p.add_argument('--prompt',help='Explicit interface smoke prompt, replacing the performance workloads')
    p.add_argument('--required-word',help='Require this word in visible app/server output')
    p.add_argument('--max-new',type=int,default=32);p.add_argument('--timeout',type=int,default=1800)
    args=p.parse_args()
    for name, allowed in [('interfaces', {'app','server'}), ('modes', {'greedy','sampled'}),
                          ('shapes', {'tiny','short','long'})]:
        if not set(getattr(args,name).split(',')) <= allowed:
            p.error(f'--{name} accepts '+','.join(sorted(allowed)))
    if min(args.repeat,args.max_new,args.timeout,args.comparison_repeat) < 1:
        p.error('repeat, max-new and timeout must be positive')
    if any(value is not None for value in (args.comparison_lookahead,args.comparison_small_block,args.comparison_shared_overlap,args.comparison_slots,args.comparison_chunk)) and not args.comparison_app:
        p.error('comparison overrides require --comparison-app')
    if any(value is not None and value < 1 for value in (args.slots,args.comparison_slots,args.chunk,args.comparison_chunk)):
        p.error('slot and chunk overrides must be positive')
    if 'app' not in args.interfaces.split(',') and any(value is not None for value in (args.slots,args.comparison_slots,args.chunk,args.comparison_chunk)):
        p.error('slot and chunk overrides apply only to the app interface; the server uses catalog settings')
    args.app=args.app.resolve();args.model_root=args.model_root.resolve()
    args.output.mkdir(parents=True,exist_ok=True)
    metadata=json.loads(subprocess.check_output(['ruby','-rjson','-e','require File.expand_path("Scripts/benchmark_models",Dir.pwd); puts JSON.generate(BENCHMARK_MODELS)'],cwd=ROOT))
    rows=[]
    for model in args.models.split(','):
        config=metadata[model]
        manifest=args.model_root/Path(config['path']).name/'manifest.json'
        model_identity=json.loads(manifest.read_text())
        for trial in range(args.comparison_repeat if args.comparison_app else 1):
            applications=[('reference',args.comparison_app),('candidate',args.app)] if args.comparison_app else [('primary',args.app)]
            if trial % 2: applications.reverse()
            for variant,app in applications:
                session=copy.copy(args)
                session.app=app.resolve()
                session.lookahead=(args.comparison_lookahead or args.lookahead) if variant=='reference' else args.lookahead
                session.small_block=(args.comparison_small_block or args.small_block) if variant=='reference' else args.small_block
                session.shared_overlap=(args.comparison_shared_overlap or args.shared_overlap) if variant=='reference' else args.shared_overlap
                selected=copy.deepcopy(config)
                slots=args.comparison_slots if variant=='reference' else args.slots
                chunk=args.comparison_chunk if variant=='reference' else args.chunk
                for option,value in [('--expert-cache-slots',slots),('--prefill-chunk-tokens',chunk)]:
                    if value is not None:
                        selected['runtime'][selected['runtime'].index(option)+1]=str(value)
                if args.comparison_app:
                    session.output=args.output/f'{model}-{trial+1}-{variant}'
                    session.output.mkdir(parents=True,exist_ok=True)
                generated=[]
                if 'app' in args.interfaces.split(','): generated += service_run(session,model,selected)
                if 'server' in args.interfaces.split(','): generated += server_run(session,model,selected)
                for row in generated:
                    row.update(variant=variant,comparison_attempt=trial,manifest_sha256=digest(manifest),
                               model_identity={k:model_identity[k] for k in ('modelID','sourceSnapshotHash','arch','quant') if k in model_identity},
                               shaders_sha256=shader_digest(session.app/'Contents/Resources/bin/TUFFCLI'))
                rows += generated
                (args.output/'results.json').write_text(json.dumps(dict(harness_sha256=digest(__file__),results=rows),indent=2))
    (args.output/'results.json').write_text(json.dumps(dict(harness_sha256=digest(__file__),results=rows),indent=2))
    return 0 if all(r['status']=='passed' for r in rows) else 1


if __name__=='__main__':
    signal.signal(signal.SIGTERM, lambda signum, frame: sys_exit_signal(signum))
    raise SystemExit(main())
