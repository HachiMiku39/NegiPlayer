#!/usr/bin/env python3
"""Local, resumable full-file Sony SensMe batch analysis. Never writes source audio.

Private state includes file paths and must not be committed or uploaded.
The owner supplies the original engine for local reference runs. This research
tool is separate from NegiPlayer's native-port target.
"""
import argparse
import base64
import concurrent.futures
import contextlib
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import sqlite3
import struct
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
STOP = threading.Event()


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        while data := stream.read(1024 * 1024):
            if STOP.is_set():
                raise InterruptedError('Cancelled')
            h.update(data)
    return h.hexdigest()


def fingerprint(path):
    s = path.stat()
    return (s.st_size, s.st_mtime_ns)


def check_audio_container(path):
    with path.open('rb') as stream:
        header = stream.read(26)
        if len(header) == 26 and header[:8] == bytes.fromhex('0005160700020000'):
            raise ValueError('Source is AppleDouble metadata, not an audio data fork')
        if header[:4] != b'RIFF' or header[8:12] != b'WAVE':
            return
        size = os.fstat(stream.fileno()).st_size
        at = 12
        while at + 8 <= size:
            stream.seek(at)
            chunk = stream.read(8)
            length = int.from_bytes(chunk[4:], 'little')
            if chunk[:4] == b'data' and length > 0:
                return  # Audio truncation/codec errors are diagnosed by the actual decoder.
            if chunk[:4] == b'LIST' and length >= 4 and stream.read(4) == b'wavl':
                return  # Segmented WAVE can put audio inside this nested list.
            if length > size-at-8:
                raise ValueError('WAVE metadata chunk is truncated before an audio payload')
            at += 8 + length + (length & 1)
        raise ValueError('WAVE container contains no audio data chunk')


def save_failure_diagnostic(state, media_id, error, job):
    directory = state/'FailedDiagnostics'
    directory.mkdir(mode=0o700, exist_ok=True)
    logs = {}
    for name in ('decode.log', 'ffmpeg.log'):
        path = job/name
        if path.is_file():
            with path.open('rb') as stream:
                stream.seek(max(0, path.stat().st_size-65536))
                logs[name] = stream.read(65536).decode('utf-8', 'replace')
    key = hashlib.sha256(media_id.encode()).hexdigest()
    atomic_json(directory/(key+'.json'), dict(mediaID=media_id,error=str(error),logs=logs,createdAt=time.time()))


def atomic_json(path, value):
    tmp = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    try:
        with tmp.open('x') as stream:
            os.chmod(tmp, 0o600)
            json.dump(value, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def parse_blob(blob):
    if not blob or len(blob) > 16 * 1024 * 1024:
        raise ValueError('Invalid SMFMF size')
    at, parts, bpm = 0, [], None
    while at < len(blob):
        if len(blob) - at < 20 or blob[at+4:at+12] != b'STAEMMLW':
            raise ValueError('Invalid SMFMF header')
        size = int.from_bytes(blob[at+16:at+20], 'big')
        if size > len(blob)-at-20:
            raise ValueError('SMFMF bounds error')
        name = blob[at:at+4].decode('ascii')
        parts.append(dict(name=name, bytes=size))
        if name == 'GBPM' and size == 4:
            candidate = struct.unpack('>f', blob[at+20:at+24])[0]
            if 0 < candidate < 1000:
                bpm = candidate
        at += 20+size
    if 'STMM' not in {p['name'] for p in parts}:
        raise ValueError('Missing SMFMF analysis chunks')
    return dict(bytes=len(blob), chunks=parts, **({'bpm': bpm} if bpm else {}))


def wp(path):
    return 'Z:' + str(path).replace('/', '\\')


def run_process(command, timeout, stderr):
    with stderr.open('w') as log:
        p = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log, start_new_session=True)
        start = time.monotonic()
        try:
            while True:
                try:
                    out, _ = p.communicate(timeout=0.25)
                    break
                except subprocess.TimeoutExpired:
                    if STOP.is_set():
                        raise InterruptedError('Cancelled')
                    if time.monotonic()-start > timeout:
                        raise TimeoutError('Decode timed out')
            if p.returncode:
                # The caller retains bounded log tails in private diagnostics before job cleanup.
                raise RuntimeError('Decoder failed (exit %s)' % p.returncode)
            return out
        finally:
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGTERM)
                try:
                    p.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, signal.SIGKILL)
                    p.wait()


class SonyWorker:
    def __init__(self, runtime, state, block_bytes):
        self.runtime, self.state, self.block_bytes = runtime, state, block_bytes
        self.process = None
        self.log = None

    def start(self):
        env = dict(os.environ, WINEPREFIX=str(self.state/'WinePrefix'), WINEDEBUG='-all',
                   WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree=d;mshtml=d', MVK_CONFIG_LOG_LEVEL='0')
        self.log = (self.state/'wine-workers.log').open('a')
        command = [str(self.runtime/'Wine Devel.app/Contents/Resources/wine/bin/wine'),
                   str(self.runtime/'python-win32/python.exe'),
                   wp(ROOT/'Resources/Enrichment/sensme_analyze_windows.py'), '--dll',
                   wp(self.runtime/'SensMe/MMLib11.dll'), '--serve', '--block-bytes', str(self.block_bytes)]
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, env=env, start_new_session=True)

    def analyze(self, pcm, out, timeout):
        if self.process is None:
            self.start()
        p = self.process
        p.stdin.write((json.dumps(dict(pcm=wp(pcm), out=wp(out)))+'\n').encode())
        p.stdin.flush()
        start = time.monotonic()
        response = bytearray()
        while True:
            if STOP.is_set():
                raise InterruptedError('Cancelled')
            if time.monotonic()-start > timeout:
                raise TimeoutError('Sony analysis timed out')
            if select.select([p.stdout], [], [], 0.25)[0]:
                chunk = os.read(p.stdout.fileno(), 4096)
                if not chunk:
                    raise RuntimeError('Sony worker exited unexpectedly')
                response.extend(chunk)
                if len(response) > 1024 * 1024:
                    raise RuntimeError('Sony worker response exceeds bound')
                if b'\n' in response:
                    value = json.loads(response)
                    if not value['ok']:
                        raise RuntimeError('Sony engine: '+value.get('error', 'unknown failure'))
                    return value['summary']

    def close(self):
        if self.process:
            p, self.process = self.process, None
            with contextlib.suppress(OSError):
                p.stdin.close()
            try:
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(p.pid, signal.SIGTERM)
                try:
                    p.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(p.pid, signal.SIGKILL)
                    p.wait()
            self.log.close()


def load_library(database):
    # A consistent SQLite read transaction includes WAL data, without a full copy of personal metadata.
    with contextlib.closing(sqlite3.connect('file:'+str(database)+'?mode=ro', uri=True)) as c:
        c.execute('BEGIN')
        roots = {rid: Path(path).resolve() for rid, path in c.execute('SELECT id,path FROM library_roots')}
        items = []
        for document, in c.execute('SELECT document FROM media_files WHERE available=1 ORDER BY id'):
            d = json.loads(document)
            root = roots[d['rootID']]
            source = (root/d['relativePath']).resolve()
            if not source.is_relative_to(root):
                raise ValueError('Library path escapes selected music root')
            items.append(dict(mediaID=d['id'], source=str(source), duration=d['duration'], codec=d['codec']))
        return items


class Batch:
    def __init__(self, args):
        self.args = args
        self.lock = threading.RLock()
        self.local = threading.local()
        self.workers = []
        self.started = time.monotonic()
        self.completed_this_run = 0
        self.state = args.state.resolve()
        with contextlib.closing(sqlite3.connect('file:'+str(args.database.resolve())+'?mode=ro',uri=True)) as source_db:
            roots = [Path(row[0]).resolve() for row in source_db.execute('SELECT path FROM library_roots')]
        if any(self.state.is_relative_to(root) for root in roots):
            raise ValueError('Analysis state must be outside the music roots')
        self.state.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state, 0o700)
        (self.state/'.gitignore').write_text('*\n')
        atomic_json(self.state/'music-roots.json',[str(root) for root in roots])
        self.records = self.state/'Records'
        self.records.mkdir(exist_ok=True)
        self.jobs = self.state/'Jobs'
        self.jobs.mkdir(exist_ok=True)
        self.db = sqlite3.connect(self.state/'analysis.sqlite', check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('''CREATE TABLE IF NOT EXISTS tasks(
            id TEXT PRIMARY KEY, source TEXT, size INTEGER, mtime_ns INTEGER, profile TEXT,
            status TEXT, error TEXT, record_key TEXT, elapsed REAL, decode_seconds REAL,
            engine_seconds REAL, audio_seconds REAL, decoder TEXT, updated REAL)''')
        self.db.execute('UPDATE tasks SET status="pending" WHERE status="running"')
        self.db.commit()
        self.profile = hashlib.sha256((digest(args.runtime/'SensMe/MMLib11.dll')+
                                      '|full-file-44100-stereo-s16-v1|'+args.decoder).encode()).hexdigest()

    def seed(self):
        items = load_library(self.args.database.resolve())
        if self.args.sample:
            # Deterministic representative formats, spread across the catalog; never shorten a song.
            groups = {}
            for x in items:
                if 90 <= x['duration'] <= 600:
                    groups.setdefault(x['codec'], []).append(x)
            selected = []
            for group in groups.values():
                selected.extend(group[::max(1, len(group)//3)][:3])
            items = selected[:self.args.sample]
        if self.args.limit:
            items = items[:self.args.limit]
        pending = []
        for item in items:
            try:
                size, modified = fingerprint(Path(item['source']))
            except OSError:
                size, modified = -1, -1
            existing = self.db.execute('SELECT size,mtime_ns,profile,status,record_key FROM tasks WHERE id=?', (item['mediaID'],)).fetchone()
            if existing and existing[:3] == (size, modified, self.profile):
                if existing[3] == 'done':
                    cached = self.records/(existing[4]+'.json')
                    try:
                        d = json.loads(cached.read_text())
                        parse_blob(base64.b64decode(d['sensme']['blob'], validate=True))
                        continue
                    except (ValueError, KeyError, OSError):
                        pass
                elif existing[3] == 'failed' and not self.args.retry_failures:
                    continue
            self.db.execute('''INSERT INTO tasks(id,source,size,mtime_ns,profile,status,audio_seconds,updated)
                VALUES(?,?,?,?,?,'pending',?,?) ON CONFLICT(id) DO UPDATE SET
                source=excluded.source,size=excluded.size,mtime_ns=excluded.mtime_ns,profile=excluded.profile,
                status='pending',error=NULL,record_key=NULL,updated=excluded.updated''',
                (item['mediaID'], item['source'], size, modified, self.profile, item['duration'], time.time()))
            item['fingerprint'] = (size, modified)
            pending.append(item)
        self.db.commit()
        return items, pending

    def worker(self):
        if not hasattr(self.local, 'sony'):
            if self.args.backend == 'parallels':
                import importlib.util
                spec = importlib.util.spec_from_file_location('sensme_vm',Path(__file__).with_name('sensme-vm.py'))
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                # Share the module's launch lock between this batch's threads.
                with self.lock:
                    if not hasattr(self,'vm_module'):
                        self.vm_module = module
                self.local.sony = self.vm_module.WindowsVMWorker(self.args.runtime,self.state,
                    ROOT/'Resources/Enrichment/sensme_analyze_windows.py',self.args.vm_id,STOP,atomic_json,self.args.block_bytes)
            else:
                self.local.sony = SonyWorker(self.args.runtime, self.state, self.args.block_bytes)
            with self.lock:
                self.workers.append(self.local.sony)
        return self.local.sony

    def analyze(self, item):
        if STOP.is_set():
            return
        media_id, source = item['mediaID'], Path(item['source'])
        key = hashlib.sha256(media_id.encode()).hexdigest()
        job = self.jobs/(key+'-'+uuid.uuid4().hex)
        start = time.monotonic()
        with self.lock:
            self.db.execute('UPDATE tasks SET status="running",updated=? WHERE id=?', (time.time(), media_id))
            self.db.commit()
        try:
            if item['fingerprint'][0] < 0:
                raise FileNotFoundError('Source missing or inaccessible')
            if source.suffix.lower() == '.iso':
                raise ValueError('Disc image requires track extraction; no PCM track decoder is configured')
            if shutil.disk_usage(self.state).free < max(2*1024**3, item['duration']*176400 + 512*1024**2):
                raise OSError('Insufficient temporary disk capacity')
            job.mkdir()
            pcm, blob_path = job/'analysis.s16le', job/'analysis.smfmf'
            before = fingerprint(source)
            if before != item['fingerprint']:
                raise ValueError('Source changed since job was queued')
            check_audio_container(source)
            decode_start = time.monotonic()
            mode = self.args.decoder
            fallback = source.suffix.lower() in ('.dsf', '.dff') or mode == 'ffmpeg'
            if not fallback:
                try:
                    out = run_process([str(self.args.decode_bin), str(source), str(pcm)], max(180, item['duration']), job/'decode.log')
                    decoded = json.loads(out)
                    source_hash, frames, decoder = decoded['sourceSHA256'], decoded['frames'], 'AVAudioConverter arm64'
                except RuntimeError:
                    if mode == 'native':
                        raise
                    fallback = True
            if fallback:
                pcm.unlink(missing_ok=True)
                source_hash = digest(source)
                run_process([str(self.args.ffmpeg), '-nostdin', '-v', 'error', '-threads', '1', '-i', str(source),
                             '-map', '0:a:0', '-vn', '-sn', '-dn', '-ac', '2', '-ar', '44100', '-c:a', 'pcm_s16le',
                             '-f', 's16le', '-n', str(pcm)], max(180, item['duration']), job/'ffmpeg.log')
                frames, decoder = pcm.stat().st_size//4, 'FFmpeg arm64 stereo downmix'
            decode_seconds = time.monotonic()-decode_start
            if frames <= 0 or pcm.stat().st_size != frames*4:
                raise ValueError('No complete PCM frames')
            summary = self.worker().analyze(pcm, blob_path, max(180, frames/44100*1.5))
            blob = blob_path.read_bytes()
            parsed = parse_blob(blob)
            if fingerprint(source) != before or digest(source) != source_hash:
                raise ValueError('Source changed during analysis')
            record = dict(mediaID=media_id, sourcePath=str(source), sourceSHA256=source_hash, candidates=[],
                          sensme=dict(sourceSHA256=source_hash, engineVersion=summary.get('engine_version') or 'Sony MMLib11',
                                      summary=parsed, blob=base64.b64encode(blob).decode(), analyzedAt=time.time()-978307200))
            atomic_json(self.records/(key+'.json'), record)
            with self.lock:
                self.db.execute('''UPDATE tasks SET status='done',error=NULL,record_key=?,elapsed=?,decode_seconds=?,
                    engine_seconds=?,audio_seconds=?,decoder=?,updated=? WHERE id=?''',
                    (key,time.monotonic()-start,decode_seconds,summary['engine_seconds'],frames/44100,decoder,time.time(),media_id))
                self.db.commit()
        except InterruptedError:
            with self.lock:
                self.db.execute('UPDATE tasks SET status="pending",error="Cancelled",updated=? WHERE id=?', (time.time(),media_id))
                self.db.commit()
            if hasattr(self.local, 'sony'):
                self.local.sony.close()
        except Exception as error:
            if hasattr(self.local, 'sony'):
                self.local.sony.close()
            try:
                save_failure_diagnostic(self.state, media_id, error, job)
            except OSError:
                pass  # The SQLite failure record must survive even if diagnostic storage is full.
            with self.lock:
                self.db.execute('UPDATE tasks SET status="failed",error=?,elapsed=?,updated=? WHERE id=?',
                                (str(error),time.monotonic()-start,time.time(),media_id))
                self.db.commit()
        finally:
            shutil.rmtree(job, ignore_errors=True)
            with self.lock:
                self.completed_this_run += 1
                self.report()

    def report(self):
        counts = dict(self.db.execute('SELECT status,count(*) FROM tasks GROUP BY status'))
        elapsed = time.monotonic()-self.started
        remaining = counts.get('pending',0)+counts.get('running',0)
        value = dict(counts=counts, elapsedSeconds=round(elapsed,2), completedThisRun=self.completed_this_run,
                     workers=self.args.workers, backend=self.args.backend, profile=self.profile,
                     etaSeconds=round(remaining*elapsed/self.completed_this_run) if self.completed_this_run else None)
        atomic_json(self.state/'progress.json',value)
        return value

    def run(self):
        _, pending = self.seed()
        print(json.dumps(dict(queued=len(pending), **self.report())), flush=True)
        # Start Wine once to avoid concurrent first-use prefix initialization.
        runtime = self.args.runtime
        env = dict(os.environ,WINEPREFIX=str(self.state/'WinePrefix'),WINEDEBUG='-all',
                   WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree=d;mshtml=d')
        if pending and self.args.backend == 'wine':
            with (self.state/'wine-init.log').open('w') as log:
                subprocess.run([str(runtime/'Wine Devel.app/Contents/Resources/wine/bin/wine'),
                                str(runtime/'python-win32/python.exe'),'-c','import ctypes'],
                               env=env, stdout=log, stderr=log, timeout=180,check=True)
        last = time.monotonic()
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=self.args.workers) as pool:
                futures = [pool.submit(self.analyze,item) for item in pending]
                waiting = set(futures)
                while waiting:
                    _, waiting = concurrent.futures.wait(waiting,timeout=1,return_when=concurrent.futures.FIRST_COMPLETED)
                    if time.monotonic()-last >= 30:
                        with self.lock:
                            print(json.dumps(self.report()),flush=True)
                        last = time.monotonic()
        finally:
            for worker in self.workers:
                worker.close()
        with self.lock:
            print(json.dumps(self.report()),flush=True)
        return 130 if STOP.is_set() else 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--database',type=Path,required=True)
    p.add_argument('--runtime',type=Path,required=True)
    p.add_argument('--state',type=Path,required=True)
    p.add_argument('--workers',type=int,default=4)
    p.add_argument('--backend',choices=('wine','parallels'),default='wine')
    p.add_argument('--vm-id',help='Existing local Windows VM with Parallels Tools and shared home already available')
    p.add_argument('--decode-bin',type=Path,required=True)
    p.add_argument('--decoder',choices=('auto','native','ffmpeg'),default='auto')
    p.add_argument('--ffmpeg',type=Path,default=Path('/opt/homebrew/bin/ffmpeg'))
    p.add_argument('--block-bytes',type=int,default=262144)
    p.add_argument('--retry-failures',action='store_true')
    p.add_argument('--sample',type=int,default=0)
    p.add_argument('--limit',type=int,default=0)
    args = p.parse_args()
    if not 1 <= args.workers <= 16:
        p.error('workers must be 1..16')
    if args.backend == 'parallels' and not args.vm_id:
        p.error('--vm-id is required for the parallels backend')
    args.runtime,args.decode_bin,args.ffmpeg = args.runtime.resolve(),args.decode_bin.resolve(),args.ffmpeg.resolve()
    if not (args.runtime/'SensMe/MMLib11.dll').is_file() or not args.decode_bin.is_file():
        p.error('Missing supplied Sony runtime or native decoder')
    signal.signal(signal.SIGINT,lambda *_:STOP.set())
    signal.signal(signal.SIGTERM,lambda *_:STOP.set())
    # Prevent overlapping runs against the same checkpoint.
    import fcntl
    with contextlib.closing(sqlite3.connect('file:'+str(args.database.resolve())+'?mode=ro',uri=True)) as c:
        if any(args.state.resolve().is_relative_to(Path(row[0]).resolve()) for row in c.execute('SELECT path FROM library_roots')):
            p.error('Analysis state must be outside the music roots')
    args.state.mkdir(parents=True,exist_ok=True)
    with (args.state/'batch.lock').open('a') as lock:
        try:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            p.error('Another batch owns this state directory')
        runner = Batch(args)
        try:
            return runner.run()
        finally:
            runner.db.close()


if __name__ == '__main__':
    raise SystemExit(main())
