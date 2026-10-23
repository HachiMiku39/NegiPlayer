#!/usr/bin/env python3
"""Finish an already running local batch: verify caches, merge them, and save a report.

This is a bounded companion to a local computation, not a network service.
"""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time

spec = importlib.util.spec_from_file_location('cache',Path(__file__).with_name('sensme-cache.py'))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state',type=Path,required=True)
    parser.add_argument('--records',type=Path,required=True)
    parser.add_argument('--validator',type=Path,required=True)
    args = parser.parse_args()
    state = args.state.resolve()
    info = json.loads((state/'process.json').read_text())
    deadline = time.monotonic()+24*3600
    while time.monotonic()<deadline:
        try:
            os.kill(info['pid'],0)
        except ProcessLookupError:
            break
        time.sleep(30)
    else:
        raise TimeoutError('Batch still active after 24 hours; completed analysis is retained')
    with contextlib.closing(sqlite3.connect('file:'+str(state/'analysis.sqlite')+'?mode=ro',uri=True)) as c:
        counts = dict(c.execute('SELECT status,count(*) FROM tasks GROUP BY status'))
        errors = [dict(reason=row[0],count=row[1]) for row in c.execute("SELECT error,count(*) FROM tasks WHERE status='failed' GROUP BY error")]
        timings = c.execute("SELECT sum(audio_seconds),sum(engine_seconds),sum(decode_seconds) FROM tasks WHERE status='done'").fetchone()
        modified = missing = 0
        for source,size,mtime_ns in c.execute('SELECT source,size,mtime_ns FROM tasks'):
            try:
                modified += cache.batch.fingerprint(Path(source)) != (size,mtime_ns)
            except OSError:
                missing += 1
    if counts.get('pending',0) or counts.get('running',0):
        cache.batch.atomic_json(state/'completion.json',dict(status='interrupted',counts=counts,finishedAt=time.time()))
        return 2
    verified = subprocess.run([str(args.validator),str(state/'Records')],capture_output=True,text=True,check=True)
    merged = cache.import_cache(state,args.records.resolve())
    report = dict(status='analysis-finished',counts=counts,failures=errors,importReport=merged,
                  changedSourceStats=modified,missingSources=missing,
                  analyzedAudioHours=round((timings[0] or 0)/3600,3),
                  aggregateEngineSeconds=round(timings[1] or 0,2),aggregateDecodeSeconds=round(timings[2] or 0,2),
                  cacheValidation=verified.stdout.strip(),finishedAt=time.time())
    cache.batch.atomic_json(state/'completion.json',report)
    print(json.dumps(report),flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
