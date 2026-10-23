#!/usr/bin/env python3
"""Resumable local native SensMe queue; streaming PCM, read-only source music.

The C library executes every analysis stage. Python schedules independent native
instances and FFmpeg only decodes. Checkpoints are isolated by a binary/decoder
profile; no original-engine cache is relabeled or reused as native work.
"""
import argparse
import base64
import concurrent.futures
import contextlib
import ctypes as C
import errno
import fcntl
import hashlib
import importlib.util
import json
import math
import os
import platform
from pathlib import Path
import select
import signal
import sqlite3
import subprocess
import threading
import time
import uuid

# Reuse only the original queue's pure inventory/container/SMFMF helpers.
_spec = importlib.util.spec_from_file_location('sensme_common', Path(__file__).with_name('sensme-library.py'))
common = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(common)
STOP = common.STOP
ENGINE_VERSION = 'NegiSensMe 1.6.1-native.2'


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    try:
        with temporary.open('x', encoding='utf-8') as stream:
            try:
                os.chmod(temporary, 0o600)
            except OSError as error:
                if error.errno not in (errno.EPERM, errno.ENOTSUP):
                    raise
            json.dump(value, stream, ensure_ascii=False, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class Summary(C.Structure):
    _fields_ = [('input_frames', C.c_uint64), ('leading_zero_frames', C.c_uint64),
                ('processed_frames', C.c_size_t), ('beat_count', C.c_size_t),
                ('descriptor_padding_pairs', C.c_size_t), ('is_short', C.c_int),
                ('has_bpm', C.c_int), ('bpm', C.c_float)]


class DecodeError(RuntimeError):
    pass


class NativeCore:
    def __init__(self, path):
        self.lib = C.CDLL(str(Path(path).resolve(strict=True)))
        lib = self.lib
        lib.negi_sensme_analyzer_create.restype = C.c_void_p
        lib.negi_sensme_analyzer_destroy.argtypes = [C.c_void_p]
        lib.negi_sensme_analyzer_write.argtypes = [C.c_void_p, C.POINTER(C.c_int16), C.c_size_t]
        lib.negi_sensme_analyzer_needs_pcm.argtypes = [C.c_void_p]
        lib.negi_sensme_analyzer_error.argtypes = [C.c_void_p]
        lib.negi_sensme_analyzer_error.restype = C.c_char_p
        lib.negi_sensme_analyzer_finish.argtypes = [C.c_void_p, C.POINTER(C.c_uint8), C.c_size_t, C.POINTER(Summary)]
        lib.negi_sensme_analyzer_finish.restype = C.c_size_t

    def failure(self, state):
        stage = self.lib.negi_sensme_analyzer_error(state)
        return RuntimeError('Native analysis failed at ' + (stage.decode() if stage else 'unknown stage'))

    def analyze(self, source, ffmpeg, dispatch_frames, timeout, log_path, pcm_decoder=None):
        state = self.lib.negi_sensme_analyzer_create()
        if not state:
            raise MemoryError('Cannot allocate native analyzer')
        process = None
        started = time.monotonic()
        fed_frames, kernel_seconds, reached_window = 0, 0.0, False
        try:
            with log_path.open('wb') as log:
                command = [str(ffmpeg), '-nostdin', '-v', 'error',
                    '-threads', '1', '-i', str(source), '-map', '0:a:0', '-vn', '-sn', '-dn',
                    '-ac', '2', '-ar', '44100', '-c:a', 'pcm_s16le', '-f', 's16le', 'pipe:1']
                if pcm_decoder:
                    command = [str(pcm_decoder), str(source)]
                process = subprocess.Popen(command,
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log,
                    bufsize=0, start_new_session=True)
                pending, eof = bytearray(), False
                block_bytes = dispatch_frames * 4
                while not eof:
                    if STOP.is_set():
                        raise InterruptedError('Cancelled')
                    if time.monotonic() - started > timeout:
                        raise TimeoutError('Streaming decoder exceeded its deadline')
                    if not select.select([process.stdout], [], [], 0.25)[0]:
                        continue
                    payload = os.read(process.stdout.fileno(), 65536)
                    eof = not payload
                    pending.extend(payload)
                    while len(pending) >= block_bytes or (eof and pending):
                        count = min(block_bytes, len(pending))
                        if count % 4:
                            raise DecodeError('Decoder ended with an incomplete stereo PCM frame')
                        samples = (C.c_int16 * (count // 2)).from_buffer_copy(pending[:count])
                        before = time.monotonic()
                        if not self.lib.negi_sensme_analyzer_write(state, samples, count // 4):
                            raise self.failure(state)
                        kernel_seconds += time.monotonic() - before
                        fed_frames += count // 4
                        del pending[:count]
                        if not self.lib.negi_sensme_analyzer_needs_pcm(state):
                            reached_window = True
                            break
                    if reached_window:
                        code = process.poll()
                        if code is not None and code != 0:
                            raise DecodeError('Decoder failed before the analysis window (exit %s)' % code)
                        break
                if not reached_window:
                    code = process.wait(timeout=5)
                    if code:
                        raise DecodeError('Decoder failed (exit %s)' % code)
                if not fed_frames:
                    raise DecodeError('Decoder produced no PCM frames')
                if STOP.is_set():
                    raise InterruptedError('Cancelled')
                before = time.monotonic()
                summary = Summary()
                size = self.lib.negi_sensme_analyzer_finish(state, None, 0, C.byref(summary))
                if not 0 < size <= 200000:
                    raise self.failure(state)
                output = (C.c_uint8 * size)()
                if self.lib.negi_sensme_analyzer_finish(state, output, size, None) != size:
                    raise self.failure(state)
                kernel_seconds += time.monotonic() - before
                return bytes(output), dict(native={name: getattr(summary, name) for name, _ in Summary._fields_},
                    decoder='AVAudioConverter arm64 stream' if pcm_decoder else 'FFmpeg arm64 stream',
                    analysisPCMFrames=fed_frames, stoppedAtWindow=reached_window,
                    decodeAndAnalysisSeconds=time.monotonic()-started, kernelSeconds=kernel_seconds)
        finally:
            if process:
                if process.poll() is None:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                process.stdout.close()
            self.lib.negi_sensme_analyzer_destroy(state)


class NativeBatch:
    def __init__(self, args):
        self.args = args
        args.state = Path(args.state).resolve()
        self.lock = threading.RLock()
        self.started = time.monotonic()
        self.completed_this_run = 0
        self.core = NativeCore(args.library)
        self.items = common.load_library(args.database)
        with contextlib.closing(sqlite3.connect(args.database.as_uri()+'?mode=ro', uri=True)) as c:
            self.roots = [Path(row[0]).resolve() for row in c.execute('SELECT path FROM library_roots')]
        if any(args.state.is_relative_to(root) for root in self.roots):
            raise ValueError('Checkpoint storage must be outside music roots')
        self.profile_spec = dict(engine=ENGINE_VERSION, librarySHA256=common.digest(args.library),
            decoderSHA256=common.digest(args.ffmpeg), dispatchFrames=args.dispatch_frames,
            pcmDecoderSHA256=common.digest(args.pcm_decoder) if args.pcm_decoder else None,
            decoder='avfoundation-default-ffmpeg-dsd-fallback-stream-v2', platform=platform.platform(),
            ffmpegVersion=subprocess.run([str(args.ffmpeg),'-version'],capture_output=True,text=True,timeout=10,check=True).stdout if args.pcm_decoder else None,
            scriptSHA256=common.digest(Path(__file__)))
        self.profile = hashlib.sha256(json.dumps(self.profile_spec, sort_keys=True).encode()).hexdigest()
        self.state = args.state/self.profile[:24]
        self.records, self.jobs = self.state/'Records', self.state/'Jobs'
        for folder in [self.state, self.records, self.jobs, self.state/'FailedDiagnostics']:
            folder.mkdir(parents=True, exist_ok=True)
        atomic_json(self.state/'profile.json', self.profile_spec)
        atomic_json(self.state/'music-roots.json', [str(p) for p in self.roots])
        atomic_json(args.state/'current.json', dict(profile=self.profile, state=str(self.state)))
        self.db = sqlite3.connect(self.state/'analysis.sqlite', check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('''CREATE TABLE IF NOT EXISTS tasks(
            id TEXT PRIMARY KEY, source TEXT, size INTEGER, mtime_ns INTEGER, profile TEXT,
            status TEXT, error TEXT, record_key TEXT, elapsed REAL, decode_seconds REAL,
            engine_seconds REAL, audio_seconds REAL, decoder TEXT, updated REAL,
            source_sha256 TEXT, result_sha256 TEXT, attempts INTEGER DEFAULT 0, native_summary TEXT)''')
        self.db.execute('CREATE INDEX IF NOT EXISTS tasks_status ON tasks(status)')
        self.db.execute("UPDATE tasks SET status='pending',error='Interrupted before checkpoint' WHERE status='running'")
        self.db.commit()

    def cached_valid(self, item, row):
        key = hashlib.sha256(item['mediaID'].encode()).hexdigest()
        if row['record_key'] != key:
            return False
        try:
            value = json.loads((self.records/(key+'.json')).read_text())
            blob = base64.b64decode(value['sensme']['blob'], validate=True)
            return (value['mediaID'] == item['mediaID'] and value['sourcePath'] == item['source'] and
                value['nativeProfile'] == self.profile and value['sensme']['engineVersion'] == ENGINE_VERSION and
                value['sourceSHA256'] == value['sensme']['sourceSHA256'] == row['source_sha256'] and
                hashlib.sha256(blob).hexdigest() == row['result_sha256'] and
                common.parse_blob(blob) == value['sensme']['summary'] and
                common.digest(Path(item['source'])) == row['source_sha256'])
        except (OSError, ValueError, KeyError):
            return False

    def seed(self):
        items = self.items
        if self.args.sample:
            groups = {}
            for item in items:
                if 30 <= item['duration'] <= 600:
                    groups.setdefault(Path(item['source']).suffix.lower(), []).append(item)
            items = [item for group in groups.values() for item in group[::max(1,len(group)//3)][:3]][:self.args.sample]
        if self.args.limit:
            items = items[:self.args.limit]
        self.selected_count = len(items)
        self.full_selection = not self.args.sample and not self.args.limit
        if self.full_selection:
            active = {item['mediaID'] for item in items}
            for (media_id,) in self.db.execute('SELECT id FROM tasks').fetchall():
                if media_id not in active:
                    self.db.execute("UPDATE tasks SET status='obsolete' WHERE id=?", (media_id,))
        pending = []
        self.db.row_factory = sqlite3.Row
        for index, item in enumerate(items):
            if STOP.is_set():
                raise InterruptedError('Cancelled while validating checkpoints')
            try:
                size, modified = common.fingerprint(Path(item['source']))
            except OSError:
                size, modified = -1, -1
            row = self.db.execute('SELECT * FROM tasks WHERE id=?', (item['mediaID'],)).fetchone()
            if row and (row['size'],row['mtime_ns'],row['profile']) == (size,modified,self.profile):
                if row['status'] == 'done' and self.cached_valid(item,row):
                    continue
                if row['status'] == 'failed' and not self.args.retry_failures:
                    if size < 0 or (row['source_sha256'] and common.digest(Path(item['source'])) == row['source_sha256']):
                        continue
            self.db.execute('''INSERT INTO tasks(id,source,size,mtime_ns,profile,status,audio_seconds,updated)
                VALUES(?,?,?,?,?,'pending',?,?) ON CONFLICT(id) DO UPDATE SET
                source=excluded.source,size=excluded.size,mtime_ns=excluded.mtime_ns,profile=excluded.profile,
                status='pending',error=NULL,record_key=NULL,source_sha256=NULL,result_sha256=NULL,updated=excluded.updated''',
                (item['mediaID'],item['source'],size,modified,self.profile,item['duration'],time.time()))
            item = dict(item, fingerprint=(size,modified));pending.append(item)
            if index and index % 250 == 0:
                self.db.commit()
        self.db.commit()
        return pending

    def analyze(self, item):
        if STOP.is_set():
            return
        media_id, source = item['mediaID'], Path(item['source'])
        key = hashlib.sha256(media_id.encode()).hexdigest()
        job = self.jobs/(key+'-'+uuid.uuid4().hex)
        started = time.monotonic()
        source_hash = None
        with self.lock:
            self.db.execute("UPDATE tasks SET status='running',attempts=attempts+1,updated=? WHERE id=?", (time.time(),media_id))
            self.db.commit()
        try:
            if item['fingerprint'][0] < 0:
                raise FileNotFoundError('Source missing or inaccessible')
            before = common.fingerprint(source)
            if before != item['fingerprint']:
                raise ValueError('Source changed since queue snapshot')
            source_hash = common.digest(source)
            if source.suffix.lower() == '.iso':
                raise ValueError('Disc image requires track extraction; no PCM track decoder is configured')
            common.check_audio_container(source)
            job.mkdir()
            decoder = self.args.pcm_decoder if source.suffix.lower() not in ('.dsf','.dff') else None
            timeout = max(180,min(7200,float(item['duration'])*2+30))
            decode_started = time.monotonic()
            fallback_reason = None
            try:
                blob,timing = self.core.analyze(source,self.args.ffmpeg,self.args.dispatch_frames,timeout,
                    job/('decode.log' if decoder else 'ffmpeg.log'),pcm_decoder=decoder)
            except DecodeError as error:
                if not decoder:
                    raise
                fallback_reason = str(error)
                blob,timing = self.core.analyze(source,self.args.ffmpeg,self.args.dispatch_frames,timeout,job/'ffmpeg.log')
            timing['totalDecodeAndAnalysisSeconds'] = time.monotonic()-decode_started
            if fallback_reason:
                timing['decoderFallbackReason'] = fallback_reason
            parsed = common.parse_blob(blob)
            if common.fingerprint(source) != before or common.digest(source) != source_hash:
                raise ValueError('Source changed during native analysis')
            if STOP.is_set():
                raise InterruptedError('Cancelled before checkpoint')
            result_hash = hashlib.sha256(blob).hexdigest()
            record = dict(mediaID=media_id,sourcePath=str(source),sourceSHA256=source_hash,candidates=[],
                nativeProfile=self.profile,nativeAnalysis=timing,
                sensme=dict(sourceSHA256=source_hash,engineVersion=ENGINE_VERSION,summary=parsed,
                    blob=base64.b64encode(blob).decode(),analyzedAt=time.time()-978307200))
            atomic_json(self.records/(key+'.json'),record)
            with self.lock:
                self.db.execute('''UPDATE tasks SET status='done',error=NULL,record_key=?,source_sha256=?,result_sha256=?,
                    elapsed=?,decode_seconds=?,engine_seconds=?,decoder=?,native_summary=?,updated=? WHERE id=?''',
                    (key,source_hash,result_hash,time.monotonic()-started,timing['totalDecodeAndAnalysisSeconds'],
                     timing['kernelSeconds'],timing['decoder']+' -> native C',json.dumps(timing),time.time(),media_id))
                self.db.commit()
        except InterruptedError:
            with self.lock:
                self.db.execute("UPDATE tasks SET status='pending',error='Cancelled',updated=? WHERE id=?", (time.time(),media_id))
                self.db.commit()
        except Exception as error:
            logs = {}
            for name in ['decode.log','ffmpeg.log']:
                log = job/name
                if log.exists():
                    with log.open('rb') as stream:
                        stream.seek(max(0,log.stat().st_size-65536));logs[name]=stream.read(65536).decode('utf-8','replace')
            with contextlib.suppress(OSError):
                atomic_json(self.state/'FailedDiagnostics'/(key+'.json'),dict(mediaID=media_id,error=str(error),decoderLogs=logs,createdAt=time.time()))
            with self.lock:
                self.db.execute("UPDATE tasks SET status='failed',error=?,source_sha256=COALESCE(?,source_sha256),elapsed=?,updated=? WHERE id=?", (str(error),source_hash,time.monotonic()-started,time.time(),media_id))
                self.db.commit()
        finally:
            import shutil
            shutil.rmtree(job,ignore_errors=True)
            with self.lock:
                self.completed_this_run += 1
                self.report()

    def report(self):
        counts = dict(self.db.execute('SELECT status,count(*) FROM tasks GROUP BY status'))
        elapsed = time.monotonic()-self.started
        remaining = counts.get('pending',0)+counts.get('running',0)
        value = dict(counts=counts,elapsedSeconds=round(elapsed,3),completedThisRun=self.completed_this_run,
            workers=self.args.workers,backend='native',profile=self.profile,state=str(self.state),
            indexedLibraryTracks=len(self.items),selectedTracks=self.selected_count,fullLibrarySelection=self.full_selection,
            etaSeconds=round(remaining*elapsed/self.completed_this_run) if self.completed_this_run else None,
            sourceMusicWrites=False,wholeTrackPCMFiles=False)
        atomic_json(self.state/'progress.json',value)
        return value

    def run(self):
        pending = self.seed()
        print(json.dumps(dict(queued=len(pending),**self.report())),flush=True)
        last = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.args.workers) as pool:
            waiting = {pool.submit(self.analyze,item) for item in pending}
            while waiting:
                done,waiting = concurrent.futures.wait(waiting,timeout=1,return_when=concurrent.futures.FIRST_COMPLETED)
                for future in done:
                    future.result()
                if time.monotonic()-last >= 30:
                    with self.lock: print(json.dumps(self.report()),flush=True)
                    last = time.monotonic()
        with self.lock:
            result = self.report()
            if not STOP.is_set():
                atomic_json(self.state/'analysis-complete.json',dict(result,finishedAt=time.time(),
                    nativeLibraryComplete=self.full_selection and not result['counts'].get('pending') and not result['counts'].get('running') and
                        result['counts'].get('done',0)+result['counts'].get('failed',0)==len(self.items),
                    failures=[dict(mediaID=r[0],reason=r[1]) for r in self.db.execute("SELECT id,error FROM tasks WHERE status='failed' ORDER BY id")]))
            print(json.dumps(result),flush=True)
        return 130 if STOP.is_set() else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database',type=Path,required=True)
    parser.add_argument('--library',type=Path,required=True,help='Locally compiled native C library')
    parser.add_argument('--state',type=Path,required=True,help='Private checkpoint root outside music folders')
    parser.add_argument('--ffmpeg',type=Path,default=Path('/opt/homebrew/bin/ffmpeg'))
    parser.add_argument('--pcm-decoder',type=Path,required=True,help='SensMePCMStream executable sharing the application AVAudioConverter')
    parser.add_argument('--workers',type=int,default=8)
    parser.add_argument('--dispatch-frames',type=int,choices=[4096,65536],default=4096)
    parser.add_argument('--sample',type=int,default=0)
    parser.add_argument('--limit',type=int,default=0)
    parser.add_argument('--retry-failures',action='store_true')
    args = parser.parse_args()
    if not 1 <= args.workers <= 16 or args.sample<0 or args.limit<0:
        parser.error('Workers must be1..16 and selection bounds nonnegative')
    args.database=args.database.resolve(strict=True);args.library=args.library.resolve(strict=True)
    args.ffmpeg=args.ffmpeg.resolve(strict=True);args.pcm_decoder=args.pcm_decoder.resolve(strict=True);args.state=args.state.resolve()
    with contextlib.closing(sqlite3.connect(args.database.as_uri()+'?mode=ro',uri=True)) as db:
        if any(args.state.is_relative_to(Path(r[0]).resolve()) for r in db.execute('SELECT path FROM library_roots')):
            parser.error('Checkpoint storage must be outside music roots')
    args.state.mkdir(parents=True,exist_ok=True);(args.state/'.gitignore').write_text('*\n')
    signal.signal(signal.SIGINT,lambda *_:STOP.set());signal.signal(signal.SIGTERM,lambda *_:STOP.set())
    with (args.state/'batch.lock').open('a') as lock:
        try:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error('Another native batch owns this checkpoint root')
        runner=None
        try:
            runner=NativeBatch(args)
            return runner.run()
        except InterruptedError:
            return 130
        finally:
            if runner: runner.db.close()


if __name__ == '__main__':
    raise SystemExit(main())
