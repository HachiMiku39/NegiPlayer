import base64
import contextlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import struct
import tempfile
import types
import unittest
from unittest.mock import patch
import threading

spec = importlib.util.spec_from_file_location('batch', Path(__file__).with_name('sensme-library.py'))
batch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batch)
cache_spec = importlib.util.spec_from_file_location('cache',Path(__file__).with_name('sensme-cache.py'))
cache = importlib.util.module_from_spec(cache_spec)
cache_spec.loader.exec_module(cache)
vm_spec = importlib.util.spec_from_file_location('vm',Path(__file__).with_name('sensme-vm.py'))
vm = importlib.util.module_from_spec(vm_spec)
vm_spec.loader.exec_module(vm)


def blob():
    def chunk(name, data):
        return name + b'STAEMMLW' + b'\x00'*4 + len(data).to_bytes(4,'big') + data
    return chunk(b'GBPM',struct.pack('>f',120)) + chunk(b'STMM',b'\x00'*8)


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.music = self.root/'Music'
        self.music.mkdir()
        self.source = self.music/'sample.flac'
        self.source.write_bytes(b'original-music')
        self.runtime = self.root/'Runtime'
        (self.runtime/'SensMe').mkdir(parents=True)
        (self.runtime/'SensMe/MMLib11.dll').write_bytes(b'test-engine')
        self.database = self.root/'Library.sqlite'
        with contextlib.closing(sqlite3.connect(self.database)) as c, c:
            c.executescript('CREATE TABLE library_roots(id,path); CREATE TABLE media_files(id,document,available);')
            c.execute('INSERT INTO library_roots VALUES(?,?)',('root',str(self.music)))
            self.item = dict(id='track',rootID='root',relativePath='sample.flac',duration=120,codec='FLAC')
            c.execute('INSERT INTO media_files VALUES(?,?,1)',('track',json.dumps(self.item)))
        self.args = types.SimpleNamespace(state=self.root/'State',runtime=self.runtime,decoder='auto',sample=0,
            limit=0,database=self.database,retry_failures=False,workers=4,backend='wine')

    def tearDown(self):
        self.tmp.cleanup()

    def save_success(self, runner):
        key = 'cached'
        batch.atomic_json(runner.records/(key+'.json'),dict(sensme=dict(blob=base64.b64encode(blob()).decode())))
        runner.db.execute("UPDATE tasks SET status='done',record_key=?",(key,))
        runner.db.commit()

    def test_resume_revalidates_cache_and_changed_sources(self):
        runner = batch.Batch(self.args)
        self.assertEqual(len(runner.seed()[1]),1)
        self.save_success(runner)
        self.assertEqual(len(runner.seed()[1]),0)
        self.source.write_bytes(b'new-music-version')
        self.assertEqual(len(runner.seed()[1]),1)
        self.save_success(runner)
        (runner.records/'cached.json').write_text('{}')
        self.assertEqual(len(runner.seed()[1]),1)
        runner.db.close()

    def test_metadata_misnamed_as_audio_has_explicit_failure_and_no_source_write(self):
        content = bytes.fromhex('0005160700020000') + b'Mac OS X        ' + b'\0\2' + b'\0'*100
        self.source.write_bytes(content)
        runner = batch.Batch(self.args)
        try:
            _, pending = runner.seed()
            runner.analyze(pending[0])
            status, error = runner.db.execute('SELECT status,error FROM tasks').fetchone()
            self.assertEqual(status, 'failed')
            self.assertIn('AppleDouble metadata', error)
            self.assertEqual(self.source.read_bytes(), content)
            self.assertEqual(list(runner.records.iterdir()), [])
            self.assertEqual(len(list((self.args.state/'FailedDiagnostics').glob('*.json'))), 1)
        finally:
            runner.db.close()

    def test_decoder_log_survives_job_cleanup_and_is_bounded(self):
        job = self.root/'job'; job.mkdir()
        (job/'decode.log').write_bytes(b'old details\n'+b'x'*100000+b'\nlast error')
        batch.save_failure_diagnostic(self.root, 'track', RuntimeError('decode failed'), job)
        import shutil
        shutil.rmtree(job)
        record = json.loads(next((self.root/'FailedDiagnostics').glob('*.json')).read_text())
        self.assertEqual(record['error'], 'decode failed')
        self.assertEqual(len(record['logs']['decode.log']), 65536)
        self.assertTrue(record['logs']['decode.log'].endswith('last error'))

    def test_wave_metadata_only_is_distinguished_from_audio_and_segmented_wave(self):
        def wave(body):
            self.source.write_bytes(b'RIFF'+(len(body)+4).to_bytes(4,'little')+b'WAVE'+body)
        wave(b'fmt '+(16).to_bytes(4,'little')+bytes(16))
        with self.assertRaisesRegex(ValueError,'no audio data chunk'):
            batch.check_audio_container(self.source)
        wave(b'data'+(4).to_bytes(4,'little')+bytes(4))
        batch.check_audio_container(self.source)
        wave(b'LIST'+(4).to_bytes(4,'little')+b'wavl')
        batch.check_audio_container(self.source)
        wave(b'JUNK'+(100).to_bytes(4,'little'))
        with self.assertRaisesRegex(ValueError,'truncated'):
            batch.check_audio_container(self.source)

    def test_failures_are_retained_and_retry_is_explicit(self):
        runner = batch.Batch(self.args)
        runner.seed()
        runner.db.execute("UPDATE tasks SET status='failed',error='unsupported'")
        runner.db.commit()
        self.assertEqual(runner.seed()[1],[])
        self.args.retry_failures = True
        self.assertEqual(len(runner.seed()[1]),1)
        self.assertEqual(self.source.read_bytes(),b'original-music')
        runner.db.close()

    def test_engine_version_change_invalidates_cached_analysis(self):
        runner = batch.Batch(self.args)
        runner.seed()
        self.save_success(runner)
        runner.db.close()
        (self.runtime/'SensMe/MMLib11.dll').write_bytes(b'new-engine')
        runner = batch.Batch(self.args)
        self.assertEqual(len(runner.seed()[1]),1)
        runner.db.close()

    def test_path_escape_is_rejected(self):
        self.item['relativePath'] = '../outside.flac'
        with contextlib.closing(sqlite3.connect(self.database)) as c, c:
            c.execute('UPDATE media_files SET document=?',(json.dumps(self.item),))
        with self.assertRaisesRegex(ValueError,'escapes'):
            batch.load_library(self.database)

    def test_blob_bounds_and_required_analysis(self):
        self.assertEqual(batch.parse_blob(blob())['bpm'],120)
        self.assertNotIn('bpm',batch.parse_blob(blob()[24:]))
        for bad in (b'',blob()[:-1],blob()[:24],b'X'*30):
            with self.assertRaises(ValueError):
                batch.parse_blob(bad)

    def test_cache_import_preserves_approved_fields_and_rejects_changed_audio(self):
        runner = batch.Batch(self.args)
        runner.seed()
        key = batch.hashlib.sha256(b'track').hexdigest()
        sha = batch.digest(self.source)
        record = dict(mediaID='track',sourcePath=str(self.source),sourceSHA256=sha,candidates=[],
                      sensme=dict(blob=base64.b64encode(blob()).decode(),sourceSHA256=sha,summary=batch.parse_blob(blob())))
        batch.atomic_json(runner.records/(key+'.json'),record)
        runner.db.execute("UPDATE tasks SET status='done',record_key=?",(key,))
        runner.db.commit()
        target = self.root/'ApplicationCache'
        target.mkdir()
        old = dict(record,approvedArtwork='approved-cover',approvedMetadata={'year':'2001'},candidates=['edition'])
        batch.atomic_json(target/(key+'.json'),old)
        self.assertEqual(cache.import_cache(runner.state,target)['imported'],1)
        merged = json.loads((target/(key+'.json')).read_text())
        self.assertEqual(merged['approvedArtwork'],'approved-cover')
        self.assertEqual(merged['candidates'],['edition'])
        self.source.write_bytes(b'changed-source')
        self.assertEqual(cache.import_cache(runner.state,target)['stale'],1)
        self.assertEqual(self.source.read_bytes(),b'changed-source')
        with self.assertRaisesRegex(ValueError,'outside'):
            cache.import_cache(runner.state,self.music/'new-cache')
        self.assertFalse((self.music/'new-cache').exists())
        runner.db.close()

    def test_state_cannot_be_created_inside_music_folder(self):
        self.args.state = self.music/'Analysis'
        with self.assertRaisesRegex(ValueError,'outside'):
            batch.Batch(self.args)
        self.assertFalse(self.args.state.exists())

    def test_guest_response_cannot_be_assigned_to_a_different_track(self):
        def respond(path,request):
            batch.atomic_json(path.parent/'response.json',dict(ok=True,nonce='different-request',summary={'bpm':120}))
        worker = vm.WindowsVMWorker(self.runtime,self.root,self.root/'helper.py','test-vm',threading.Event(),respond,262144)
        worker.process = types.SimpleNamespace(poll=lambda:None)
        worker.folder = self.root
        with patch.object(vm,'shared_path',side_effect=str):
            with self.assertRaisesRegex(RuntimeError,'identity mismatch'):
                worker.analyze(self.root/'input.s16le',self.root/'out.smfmf',1)

    def test_guest_paths_are_confined_to_the_shared_home(self):
        self.assertTrue(vm.shared_path(Path.home()/'Library/Application Support/NegiPlayer/analysis.s16le').startswith('\\\\Mac\\Home\\'))
        with self.assertRaises(ValueError):
            vm.shared_path(Path('/Volumes/UnsharedMusic/source.flac'))


if __name__ == '__main__':
    unittest.main()
