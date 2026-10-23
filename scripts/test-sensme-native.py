"""Checkpoint/import tests use a fake kernel; integration uses the real C core separately."""
import base64
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import struct
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch


def module(name, file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


native=module('native','sensme-native.py')
cache=module('cache','sensme-cache.py')


def blob():
    def chunk(name,data):return name+b'STAEMMLW'+b'\x01\x00\x80\x00'+len(data).to_bytes(4,'big')+data
    return chunk(b'GBPM',struct.pack('>f',120))+chunk(b'STMM',bytes(8))


class FakeCore:
    error=None
    calls=0
    started=None

    def __init__(self,*_):pass

    def analyze(self,source,ffmpeg,dispatch,timeout,log,pcm_decoder=None):
        type(self).calls+=1
        if self.started:
            self.started.set()
            while not native.STOP.wait(0.01):pass
            raise InterruptedError('Cancelled')
        if self.error:
            log.write_bytes(b'x'*70000+b'\nlast decode error')
            raise self.error
        return blob(),dict(native=dict(processed_frames=4096,has_bpm=1),analysisPCMFrames=44100*35,
            stoppedAtWindow=False,decodeAndAnalysisSeconds=0.02,kernelSeconds=0.01,decoder='test decoder')


class NativeQueueTests(unittest.TestCase):
    def setUp(self):
        native.STOP.clear();FakeCore.error=None;FakeCore.calls=0;FakeCore.started=None
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.music=self.root/'Music';self.music.mkdir();self.source=self.music/'generated.flac'
        self.source.write_bytes(b'original-music')
        self.library=self.root/'native.dylib';self.library.write_bytes(b'kernel1')
        self.ffmpeg=self.root/'ffmpeg';self.ffmpeg.write_bytes(b'decoder1')
        self.database=self.root/'Library.sqlite'
        with contextlib.closing(sqlite3.connect(self.database)) as db,db:
            db.executescript('CREATE TABLE library_roots(id,path);CREATE TABLE media_files(id,document,available);')
            db.execute('INSERT INTO library_roots VALUES(?,?)',('root',str(self.music)))
            db.execute('INSERT INTO media_files VALUES(?,?,1)',('track',json.dumps(dict(id='track',rootID='root',relativePath=self.source.name,duration=120,codec='FLAC'))))
        self.args=types.SimpleNamespace(database=self.database,library=self.library,ffmpeg=self.ffmpeg,state=self.root/'State',
            workers=2,dispatch_frames=4096,sample=0,limit=0,retry_failures=False,pcm_decoder=None)
        self.mock=patch.object(native,'NativeCore',FakeCore);self.mock.start()

    def tearDown(self):
        self.mock.stop();native.STOP.clear()

    def runner(self):
        runner=native.NativeBatch(self.args);self.addCleanup(runner.db.close);return runner

    def test_resume_verifies_source_even_when_size_and_mtime_are_preserved(self):
        runner=self.runner();pending=runner.seed();runner.analyze(pending[0]);self.assertEqual(len(runner.seed()),0)
        before=self.source.stat();self.source.write_bytes(b'modified-music');os.utime(self.source,ns=(before.st_atime_ns,before.st_mtime_ns))
        self.assertEqual(self.source.stat().st_size,before.st_size)
        self.assertEqual(self.source.stat().st_mtime_ns,before.st_mtime_ns)
        self.assertEqual(len(runner.seed()),1)

    def test_changed_cache_blob_is_not_accepted_as_a_completed_checkpoint(self):
        runner=self.runner();runner.analyze(runner.seed()[0]);path=next(runner.records.glob('*.json'));value=json.loads(path.read_text())
        value['sensme']['blob']=base64.b64encode(blob().replace(struct.pack('>f',120),struct.pack('>f',121))).decode()
        value['sensme']['summary']=native.common.parse_blob(base64.b64decode(value['sensme']['blob']))
        path.write_text(json.dumps(value));self.assertEqual(len(runner.seed()),1)

    def test_kernel_profile_change_keeps_the_old_checkpoint_directory(self):
        first=self.runner();first.analyze(first.seed()[0]);old=first.state;record=next(first.records.glob('*.json')).read_bytes()
        self.library.write_bytes(b'kernel2');second=self.runner()
        self.assertNotEqual(first.profile,second.profile);self.assertNotEqual(old,second.state)
        self.assertEqual(len(second.seed()),1);self.assertEqual(next(first.records.glob('*.json')).read_bytes(),record)

    def test_failures_are_explicit_bounded_and_require_retry(self):
        runner=self.runner();FakeCore.error=RuntimeError('decode failure');runner.analyze(runner.seed()[0])
        row=runner.db.execute('SELECT status,error,attempts FROM tasks').fetchone();self.assertEqual(tuple(row),('failed','decode failure',1))
        diagnostic=json.loads(next((runner.state/'FailedDiagnostics').glob('*.json')).read_text())
        self.assertEqual(len(diagnostic['decoderLogs']['ffmpeg.log']),65536);self.assertTrue(diagnostic['decoderLogs']['ffmpeg.log'].endswith('last decode error'))
        self.assertEqual(list(runner.jobs.iterdir()),[]);self.assertEqual(len(runner.seed()),0)
        self.assertEqual(runner.db.execute('SELECT source_sha256 FROM tasks').fetchone()[0],native.common.digest(self.source))
        self.args.retry_failures=True;FakeCore.error=None;runner.analyze(runner.seed()[0])
        self.assertEqual(tuple(runner.db.execute('SELECT status,attempts FROM tasks').fetchone()),('done',2))

    def test_failed_source_replacement_is_requeued_even_with_same_size_and_mtime(self):
        runner=self.runner();FakeCore.error=RuntimeError('bad source');runner.analyze(runner.seed()[0]);before=self.source.stat()
        self.source.write_bytes(b'modified-music');os.utime(self.source,ns=(before.st_atime_ns,before.st_mtime_ns))
        self.assertEqual(len(runner.seed()),1)

    def test_interruption_returns_running_track_to_pending(self):
        runner=self.runner();item=runner.seed()[0];FakeCore.started=threading.Event()
        thread=threading.Thread(target=runner.analyze,args=(item,));thread.start()
        self.assertTrue(FakeCore.started.wait(2));native.STOP.set();thread.join(2);self.assertFalse(thread.is_alive())
        self.assertEqual(tuple(runner.db.execute('SELECT status,error FROM tasks').fetchone()),('pending','Cancelled'))
        self.assertEqual(list(runner.records.iterdir()),[])

    def test_checkpoint_inside_music_is_rejected_before_creating_files(self):
        self.args.state=self.music/'State'
        with self.assertRaisesRegex(ValueError,'outside music'):
            native.NativeBatch(self.args)
        self.assertFalse(self.args.state.exists());self.assertEqual(self.source.read_bytes(),b'original-music')

    def test_full_run_preserves_source_and_records_an_explicit_terminal_inventory(self):
        runner=self.runner();before=native.common.digest(self.source);self.assertEqual(runner.run(),0)
        self.assertEqual(native.common.digest(self.source),before)
        self.assertEqual(FakeCore.calls,1);report=json.loads((runner.state/'analysis-complete.json').read_text())
        self.assertTrue(report['nativeLibraryComplete']);self.assertEqual(report['counts'],{'done':1})
        self.assertFalse(report['wholeTrackPCMFiles']);self.assertEqual(runner.run(),0);self.assertEqual(FakeCore.calls,1)

    def test_import_preserves_legacy_versions_and_approved_metadata(self):
        legacy=dict(sourceSHA256='hash',engineVersion='Sony 640',blob='old')
        new=dict(mediaID='track',sourcePath='path',sourceSHA256='hash',nativeProfile='profile2',sensme=dict(sourceSHA256='hash',engineVersion=native.ENGINE_VERSION,blob='new'))
        old=dict(new,sensme=legacy,approvedMetadata=dict(title='Approved'),nativeProfile='profile1')
        merged=cache.merge(old,new);self.assertEqual(merged['approvedMetadata'],old['approvedMetadata'])
        self.assertEqual(merged['sensmeHistory'],[legacy]);self.assertEqual(merged['nativeProfile'],'profile2')
        again=cache.merge(merged,new);self.assertEqual(again['sensmeHistory'],[legacy])
        changed=dict(new,sourceSHA256='changed',sensme=dict(new['sensme'],sourceSHA256='changed'))
        changed=cache.merge(merged,changed);self.assertNotIn('approvedMetadata',changed)
        self.assertEqual(len(changed['sensmeHistory']),2)

    def test_import_validates_result_digest_and_writes_a_reusable_blob_checksum(self):
        runner=self.runner();runner.analyze(runner.seed()[0]);path=next(runner.records.glob('*.json'));original=path.read_bytes()
        value=json.loads(original);payload=bytearray(base64.b64decode(value['sensme']['blob']));payload[-1]^=1
        value['sensme']['blob']=base64.b64encode(payload).decode();path.write_text(json.dumps(value))
        destination=self.root/'App'/'Records'
        report=cache.import_cache(runner.state,destination);self.assertEqual(report['failed'],1);self.assertEqual(report['imported'],0)
        self.assertEqual(list(destination.glob('*.json')),[])
        path.write_bytes(original);report=cache.import_cache(runner.state,destination);self.assertEqual(report['imported'],1)
        imported=json.loads(next(destination.glob('*.json')).read_text())
        self.assertEqual(imported['sensme']['blobSHA256'],native.common.hashlib.sha256(base64.b64decode(imported['sensme']['blob'])).hexdigest())

    def test_import_keeps_explicit_per_track_failure_records(self):
        runner=self.runner();FakeCore.error=RuntimeError('generated decode failure');runner.analyze(runner.seed()[0])
        destination=self.root/'App'/'Records';report=cache.import_cache(runner.state,destination)
        self.assertEqual(report['failuresImported'],1);self.assertEqual(report['imported'],0)
        failure=json.loads(next((destination.parent/'SensMeFailures').glob('*.json')).read_text())
        self.assertEqual(failure['mediaID'],'track');self.assertEqual(failure['sourcePath'],str(self.source.resolve()))
        self.assertEqual(failure['message'],'generated decode failure');self.assertGreater(failure['failedAt'],0)


class NativePipeIntegrationTests(unittest.TestCase):
    def setUp(self):
        path=os.environ.get('NEGI_NATIVE_LIBRARY')
        if not path:self.skipTest('Optional real native C library for pipe lifecycle checks')
        native.STOP.clear();self.core=native.NativeCore(Path(path))
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.source=self.root/'unused-source';self.source.write_bytes(b'read-only source')

    def tearDown(self):native.STOP.clear()

    def executable(self,body):
        path=self.root/'decoder';path.write_text('#!'+sys.executable+'\n'+body);path.chmod(0o700);return path

    def test_cancellation_reaps_the_confirmed_live_decoder_process(self):
        marker=self.root/'pid';result=[]
        decoder=self.executable('import os,sys,time\nfrom pathlib import Path\nPath('+repr(str(marker))+').write_text(str(os.getpid()))\nsys.stdout.buffer.write(bytes(16384));sys.stdout.buffer.flush()\ntime.sleep(30)\n')
        def run():
            try:self.core.analyze(self.source,decoder,4096,60,self.root/'decoder.log')
            except Exception as error:result.append(error)
        thread=threading.Thread(target=run);thread.start();deadline=time.monotonic()+5
        while not marker.exists() and time.monotonic()<deadline:time.sleep(0.01)
        self.assertTrue(marker.exists());pid=int(marker.read_text());os.kill(pid,0)
        native.STOP.set();thread.join(5);self.assertFalse(thread.is_alive())
        self.assertEqual(len(result),1);self.assertIsInstance(result[0],InterruptedError)
        with self.assertRaises(ProcessLookupError):os.kill(pid,0)
        self.assertEqual(self.source.read_bytes(),b'read-only source')

    def test_partial_frames_and_decoder_failures_are_not_cached_as_success(self):
        for body in ['import sys\nsys.stdout.buffer.write(bytes(3))\n',
                     'import sys\nsys.stdout.buffer.write(bytes(16384));sys.stdout.buffer.flush()\nsys.exit(5)\n']:
            with self.subTest(body=body):
                decoder=self.executable(body)
                with self.assertRaises(native.DecodeError):self.core.analyze(self.source,decoder,4096,10,self.root/'decode.log')


if __name__=='__main__':unittest.main()
