#!/usr/bin/env python3
"""Launch one benchmark, recording RSS for its PID and newly spawned WebKit helpers.

Run apps sequentially and avoid opening other WebKit apps during the sample.
WebKit services are reparented to launchd; report newly observed helpers separately
so their attribution and RSS's shared-page double counting remain explicit.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('kind', choices=['native', 'tauri'])
parser.add_argument('index')
parser.add_argument('output')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = Path(args.output).resolve()

def processes():
    rows = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,comm='], text=True).splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4:
            pid, parent, rss, command = parts
            rows[int(pid)] = {'parent': int(parent), 'rssKiB': int(rss), 'command': command}
    return rows

existing = set(processes())
env = os.environ.copy()
if args.kind == 'native':
    command = [str(root / 'build/Cardinal Native.app/Contents/MacOS/CardinalNativePrototype'),
               '--index', str(Path(args.index).resolve()), '--benchmark', str(output)]
else:
    command = [str(root / 'build/Cardinal Tauri Baseline.app/Contents/MacOS/cardinal')]
    env['CARDINAL_BENCHMARK_INDEX'] = str(Path(args.index).resolve())
    env['CARDINAL_BENCHMARK_OUTPUT'] = str(output)
records = []
with open(str(output)+'.log', 'w') as log:
    child = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
    started = time.monotonic()
    try:
        while child.poll() is None:
            current = processes()
            selected = {pid: info for pid, info in current.items() if pid == child.pid or
                        (args.kind == 'tauri' and pid not in existing and 'com.apple.WebKit.' in info['command'])}
            records.append({'elapsedSeconds': time.monotonic()-started, 'processes': selected,
                            'totalRSSKiB': sum(p['rssKiB'] for p in selected.values())})
            if time.monotonic()-started > 150:
                raise TimeoutError('Benchmark did not finish in 150 seconds')
            time.sleep(0.2)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
        Path(str(output)+'.memory.json').write_text(json.dumps({'pid': child.pid, 'exitCode': child.returncode,
            'helperAttribution': 'WebKit helper PIDs first observed during this isolated app run', 'samples': records}, indent=2))
if child.returncode != 0:
    raise SystemExit(child.returncode)
if not output.exists():
    raise SystemExit('No benchmark report was produced')
print(output)
