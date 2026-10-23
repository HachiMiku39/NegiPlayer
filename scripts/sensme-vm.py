"""Parallels local Windows worker: the Mac owns decoding, source checks and cache writes.

Only generated PCM and opaque analysis results cross the existing local shared-home interface.
No audio source paths, credentials or library database are sent to the guest process.
"""
import contextlib
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid

LAUNCH_LOCK = threading.Lock()
PRL = '/Applications/Parallels Desktop.app/Contents/MacOS/prlctl'


def shared_path(path):
    relative = path.resolve().relative_to(Path.home().resolve())
    return '\\\\Mac\\Home\\'+str(relative).replace('/','\\')


class WindowsVMWorker:
    def __init__(self,runtime,state,helper,vm_id,stop_event,write_json,block_bytes):
        self.runtime,self.state,self.helper,self.vm_id = runtime,state,helper,vm_id
        self.stop_event,self.write_json,self.block_bytes = stop_event,write_json,block_bytes
        self.process,self.folder,self.log = None,None,None

    def start(self):
        with LAUNCH_LOCK:
            for attempt in range(3):
                self.folder = self.state/'VMWorkers'/uuid.uuid4().hex
                self.folder.mkdir(parents=True)
                self.log = (self.folder/'guest.log').open('w')
                command = [PRL,'exec',self.vm_id,'--current-user',shared_path(self.runtime/'python-win32/python.exe'),
                           '-X','utf8',shared_path(self.helper),'--dll',shared_path(self.runtime/'SensMe/MMLib11.dll'),
                           '--file-worker',shared_path(self.folder),'--block-bytes',str(self.block_bytes)]
                self.process = subprocess.Popen(command,stdout=self.log,stderr=self.log,stdin=subprocess.DEVNULL,start_new_session=True)
                deadline = time.monotonic()+120
                while time.monotonic()<deadline:
                    if self.stop_event.is_set():
                        self.close()
                        raise InterruptedError('Cancelled')
                    ready = self.folder/'ready.json'
                    if ready.exists():
                        value = json.loads(ready.read_text())
                        if value['pointerBytes'] != 4:
                            self.close()
                            raise RuntimeError('Sony guest worker is not 32-bit')
                        return
                    if self.process.poll() is not None:
                        break
                    time.sleep(0.05)
                self.close()
                if attempt<2:
                    time.sleep(1)
            raise RuntimeError('Local Windows analysis worker could not start')

    def analyze(self,pcm,out,timeout):
        if self.process is None:
            self.start()
        nonce = uuid.uuid4().hex
        self.write_json(self.folder/'request.json',dict(pcm=shared_path(pcm),out=shared_path(out),nonce=nonce))
        deadline = time.monotonic()+timeout
        response = self.folder/'response.json'
        while time.monotonic()<deadline:
            if self.stop_event.is_set():
                raise InterruptedError('Cancelled')
            if response.exists():
                value = json.loads(response.read_text(encoding='utf-8'))
                response.unlink()
                if value.get('nonce') != nonce:
                    raise RuntimeError('Local Windows response identity mismatch')
                if not value['ok']:
                    raise RuntimeError('Sony engine: '+value.get('error','unknown failure'))
                return value['summary']
            if self.process.poll() is not None:
                raise RuntimeError('Local Windows worker exited unexpectedly')
            time.sleep(0.025)
        raise TimeoutError('Local Windows analysis timed out')

    def close(self):
        if self.folder:
            with contextlib.suppress(OSError):
                (self.folder/'stop').touch()
        if self.process:
            p,self.process = self.process,None
            try:
                p.wait(timeout=8)
            except subprocess.TimeoutExpired:
                # Only end our prlctl bridge. The guest sees its stop marker, or its bounded idle timer.
                p.terminate()
                try:
                    p.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
        if self.log:
            self.log.close()
            self.log = None
