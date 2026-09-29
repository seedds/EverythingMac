#!/usr/bin/env python3
"""Run sorting cases sequentially; never modify the index or app preferences."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary")
parser.add_argument("index")
parser.add_argument("output", type=Path)
parser.add_argument("--timeout", type=float, default=60, help="Seconds per process, including index load")
parser.add_argument("--names", default="small,medium,large,larger,broad,all")
parser.add_argument("--keys", default="filename,fullPath,size,mtime,ctime")
parser.add_argument("--resume", action="store_true")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
queries = [("small", "everything-mac"), ("medium", ".swift"), ("large", ".js"),
           ("larger", ".py"), ("broad", "a"), ("all", "")]
queries = [(name, query) for name, query in queries if name in args.names.split(",")]
cases = [(name, query, "none") for name, query in queries]
cases += [(name, query, key)
          for name, query in queries
          for key in args.keys.split(",")]
for number, (name, query, key) in enumerate(cases, 1):
    output = args.output / f"{name}-{key}.json"
    if args.resume and output.exists():
        continue
    print(f"Case {number}/{len(cases)}: {name} {key}", flush=True)
    try:
        subprocess.run([args.binary, args.index, query, key, "6", str(output)],
                       check=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        report = json.loads(output.read_text()) if output.exists() else {}
        report.update(query=query, sort_key=key,
                      status="timed_out", process_timeout_seconds=args.timeout)
        output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"Timed out after {args.timeout} seconds", flush=True)
reports = [json.loads(path.read_text()) for path in sorted(args.output.glob("*.json"))
           if path.name != "results.json"]
(args.output / "results.json").write_text(json.dumps(reports, indent=2) + "\n")
