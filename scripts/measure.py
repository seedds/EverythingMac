#!/usr/bin/env python3
"""Launch an EverythingMac benchmark and sample its process RSS."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
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

command = [str(root / 'build/EverythingMac.app/Contents/MacOS/EverythingMac'),
           '--index', str(Path(args.index).resolve()), '--benchmark', str(output)]
records = []
with open(str(output)+'.log', 'w') as log:
    child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    started = time.monotonic()
    try:
        while child.poll() is None:
            current = processes()
            selected = {pid: info for pid, info in current.items() if pid == child.pid}
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
            'processAttribution': 'EverythingMac benchmark process only', 'samples': records}, indent=2))
if child.returncode != 0:
    raise SystemExit(child.returncode)
if not output.exists():
    raise SystemExit('No benchmark report was produced')
print(output)
