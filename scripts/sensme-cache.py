#!/usr/bin/env python3
"""Merge completed local SensMe results into NegiPlayer's existing per-track cache.

Only local analysis JSON records are written. Source music and the library database stay read-only.
"""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import time

spec = importlib.util.spec_from_file_location('sensme_batch',Path(__file__).with_name('sensme-library.py'))
batch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batch)


def merge(existing, analyzed):
    if existing and existing.get('sourceSHA256') == analyzed['sourceSHA256']:
        value = dict(existing, mediaID=analyzed['mediaID'],sourcePath=analyzed['sourcePath'],sensme=analyzed['sensme'])
    else:
        value = dict(analyzed)
    for field in ('nativeProfile','nativeAnalysis'):
        if field in analyzed:
            value[field] = analyzed[field]
        else:
            value.pop(field,None)
    if existing:
        history = list(existing.get('sensmeHistory') or [])
        previous = existing.get('sensme')
        def identity(result):
            if not isinstance(result,dict):
                raise ValueError('Malformed SensMe history record')
            return result.get('engineVersion'),result.get('sourceSHA256'),result.get('blob')
        if previous and identity(previous) != identity(analyzed['sensme']) and all(identity(item) != identity(previous) for item in history):
            history.append(previous)
        if history:
            value['sensmeHistory'] = history
    return value


def import_cache(state, records):
    import base64
    state,records = state.resolve(),records.resolve()
    imported, stale, failed = 0, 0, 0
    with contextlib.closing(sqlite3.connect('file:'+str(state/'analysis.sqlite')+'?mode=ro',uri=True)) as c:
        columns = {row[1] for row in c.execute('PRAGMA table_info(tasks)')}
        result_hash_column = 'result_sha256' if 'result_sha256' in columns else 'NULL'
        rows = list(c.execute("SELECT id,source,size,mtime_ns,record_key,"+result_hash_column+" FROM tasks WHERE status='done'"))
        sources = [Path(row[0]).resolve() for row in c.execute('SELECT source FROM tasks')]
        analysis_failures = list(c.execute("SELECT id,source,error,updated FROM tasks WHERE status='failed'"))
    roots_file = state/'music-roots.json'
    roots = [Path(x).resolve() for x in json.loads(roots_file.read_text())] if roots_file.exists() else []
    if any(records.is_relative_to(root) for root in roots) or any(records == path or records.is_relative_to(path.parent) or path.is_relative_to(records) for path in sources):
        raise ValueError('Cache destination must be outside source music roots')
    records.mkdir(parents=True,exist_ok=True)
    failure_records = records.parent/'SensMeFailures'
    if any(failure_records.is_relative_to(root) for root in roots):
        raise ValueError('Failure cache must be outside source music roots')
    failure_records.mkdir(parents=True,exist_ok=True)
    for index,(media_id,source,size,modified,key,result_hash) in enumerate(rows):
        try:
            data = json.loads((state/'Records'/(key+'.json')).read_text())
            if data['mediaID'] != media_id or key != batch.hashlib.sha256(media_id.encode()).hexdigest():
                raise ValueError('Cache identity mismatch')
            blob = base64.b64decode(data['sensme']['blob'],validate=True)
            digest = batch.hashlib.sha256(blob).hexdigest()
            if result_hash and result_hash != digest:
                raise ValueError('Cache result digest does not match its checkpoint')
            if batch.parse_blob(blob) != data['sensme']['summary']:
                raise ValueError('Cache summary does not match SMFMF blob')
            if data['sourceSHA256'] != data['sensme']['sourceSHA256']:
                raise ValueError('Cache source digest mismatch')
            data['sensme']['blobSHA256'] = digest
            path = Path(source)
            # Full digest validation also protects against size/mtime-preserving changes.
            if batch.fingerprint(path) != (size,modified) or batch.digest(path) != data['sourceSHA256']:
                stale += 1
                continue
            target = records/(key+'.json')
            for attempt in range(3):
                version = batch.fingerprint(target) if target.exists() else None
                old = json.loads(target.read_text()) if version else None
                value = merge(old,data)
                # Preserve concurrent tag/cover changes if the app saved while we loaded the record.
                if (batch.fingerprint(target) if target.exists() else None) != version:
                    continue
                batch.atomic_json(target,value)
                (failure_records/(key+'.json')).unlink(missing_ok=True)
                imported += 1
                break
            else:
                failed += 1
        except (OSError,ValueError,KeyError):
            failed += 1
        finally:
            if (index+1)%250 == 0:
                batch.atomic_json(state/'import-progress.json',dict(processed=index+1,total=len(rows),imported=imported,stale=stale,failed=failed,updatedAt=time.time()))
    failures_imported = 0
    for media_id,source,error,updated in analysis_failures:
        try:
            key = batch.hashlib.sha256(media_id.encode()).hexdigest()
            batch.atomic_json(failure_records/(key+'.json'),dict(mediaID=media_id,sourcePath=source,message=error,failedAt=updated-978307200))
            failures_imported += 1
        except (OSError,ValueError,TypeError):
            failed += 1
    report = dict(imported=imported,stale=stale,failed=failed,failuresImported=failures_imported,finishedAt=time.time())
    batch.atomic_json(state/'import-report.json',report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state',type=Path,required=True)
    parser.add_argument('--records',type=Path,required=True)
    args = parser.parse_args()
    state,records = args.state.resolve(),args.records.resolve()
    if state == records or records.is_relative_to(state/'Jobs'):
        parser.error('Choose the application Records directory, separate from batch state')
    with contextlib.closing(sqlite3.connect('file:'+str(state/'analysis.sqlite')+'?mode=ro',uri=True)) as c:
        sources = [Path(row[0]).resolve() for row in c.execute('SELECT source FROM tasks')]
    if any(records == path or records.is_relative_to(path.parent) for path in sources):
        parser.error('Cache destination must be outside source music folders')
    print(json.dumps(import_cache(state,records)))


if __name__ == '__main__':
    main()
