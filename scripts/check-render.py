#!/usr/bin/env python3
"""Check local rendering and RSS budgets for the fixed benchmark snapshot."""
import json
from pathlib import Path
import statistics
import sys

report = json.loads(Path(sys.argv[1]).read_text())
if report.get('error'):
    raise SystemExit(report['error'])
failed = False
for query in ['EE.en', 'everything-mac', 'package.json', 'a']:
    rows = [s for s in report['samples'] if s['query'] == query]
    if len(rows) < 20:
        raise SystemExit('Incomplete benchmark')
    overhead = statistics.median(s['submissionToDrawMS'] - s['backendMS'] for s in rows)
    print(f'{query}: median UI/queue/page overhead {overhead:.1f} ms (budget 30 ms)')
    failed |= overhead > 30
memory = json.loads(Path(sys.argv[1] + '.memory.json').read_text())
if memory['exitCode'] != 0:
    raise SystemExit('Benchmark process did not exit successfully')
rss = [s['totalRSSKiB'] / 1024 for s in memory['samples'] if s['elapsedSeconds'] > 3]
peak = max(rss)
print(f'Peak process RSS {peak:.0f} MiB (budget 1024 MiB for this fixed snapshot)')
failed |= peak > 1024
raise SystemExit(1 if failed else 0)
