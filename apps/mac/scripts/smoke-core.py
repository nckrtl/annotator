#!/usr/bin/env python3
"""Exercise the real core over its private pipes, with an isolated home and server."""
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
MAC = ROOT / 'apps/mac'


def wait_for(fn, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError('Timed out waiting for expected state')


def main():
    with tempfile.TemporaryDirectory(prefix='annotator-smoke-') as directory:
        temp = Path(directory)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        base = f'http://127.0.0.1:{port}/annotations'
        settings_dir = temp / 'Library/Application Support/com.nckrtl.annotator'
        settings_dir.mkdir(parents=True)
        (settings_dir / 'settings.json').write_text(json.dumps({
            'serverURL': base, 'serverAutoStart': False, 't3Enabled': False,
            'ofideEnabled': False, 'ofideAutoStart': False,
        }))
        helper = temp / 'helper.py'
        helper.write_text('''#!/usr/bin/env python3
import json, sys, uuid

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    command = json.loads(line)
    action = command.get('action')
    if action == 'ping': emit({'type': 'online'})
    if action == 'permissions': emit({'type': 'permissions', 'accessibility': True, 'screenRecording': True})
    if action == 'selectAt' or (action == 'annotate' and command.get('on')):
        record = {'id': str(uuid.uuid4()), 'comment': '', 'element': 'AXButton "Save"',
            'url': 'app://com.example.fixture', 'screenshot': 'data:image/png;base64,aGVsbG8=',
            'native': {'app': {'name': 'Fixture', 'bundleId': 'com.example.fixture', 'pid': 123},
                       'window': {'title': 'Fixture window'}, 'mode': 'element', 'project': None}}
        emit({'type': 'selected', 'record': record, 'frame': {'x': 40, 'y': 80, 'width': 150, 'height': 35},
              'label': 'Fixture · Save', 'mode': 'element'})
''')
        helper.chmod(0o700)
        server_log = (temp / 'server.log').open('w')

        def start_server():
            server = subprocess.Popen(['node', str(ROOT / 'packages/annotator/bin/serve.mjs'),
                'serve', '--port', str(port), '--store', str(temp / 'store')], stdout=server_log, stderr=server_log)
            def available():
                try:
                    with urllib.request.urlopen(base, timeout=0.3) as response:
                        return json.load(response)['meta']['service'] == '@nckrtl/annotator'
                except Exception:
                    return False
            wait_for(available)
            return server

        server = start_server()
        process = None
        try:
            environment = os.environ | {'HOME': str(temp), 'ANNOTATOR_HELPER': str(helper)}
            stderr = (temp / 'core.log').open('w')
            process = subprocess.Popen([str(MAC / 'src-tauri/target/debug/annotator')], env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True, bufsize=1)
            messages = queue.Queue()
            events = []
            def read():
                for line in process.stdout:
                    messages.put(json.loads(line))
            threading.Thread(target=read, daemon=True).start()
            serial = 0
            def call(operation, **args):
                nonlocal serial
                serial += 1
                identity = str(serial)
                process.stdin.write(json.dumps({'id': identity, 'command': operation, 'args': args}) + '\n')
                process.stdin.flush()
                while True:
                    message = messages.get(timeout=15)
                    if message.get('id') == identity:
                        if 'error' in message:
                            raise RuntimeError(message['error'])
                        return message.get('result')
                    events.append(message)
            wait_for(lambda: call('get_state')['permissions']['accessibility'])
            assert any(e.get('event') == 'register-hotkey' for e in events)
            settings = call('get_settings')
            settings['t3Effort'] = 'high'
            assert call('save_settings', settings=settings)['t3Effort'] == 'high'
            assert json.loads((settings_dir / 'settings.json').read_text())['t3Effort'] == 'high'
            assert call('save_projects', routes={'projects': [{'id': 'fixture', 'name': 'Fixture project',
                'root': str(temp), 'bundleIds': ['com.example.fixture']}]}) is None
            call('toggle_annotating')
            wait_for(lambda: any(e.get('event') == 'comment-opened' for e in events) or (call('get_state') and False))
            call('submit_comment', text='Native bridge smoke test')
            items = wait_for(lambda: call('get_queue'))
            first = items[0]
            assert first['comment'] == 'Native bridge smoke test'
            assert first['native']['project'] == 'Fixture project'
            assert call('get_screenshot', id=first['id']).startswith('data:image/png;')
            assert any(e.get('event') == 'queue' for e in events)
            server.terminate(); server.wait(timeout=5)
            call('helper', command={'action': 'selectAt', 'x': 20, 'y': 20})
            time.sleep(0.1)
            call('submit_comment', text='Saved while offline')
            wait_for(lambda: call('get_state')['pending']['count'] == 1)
            server = start_server()
            call('retry_now')
            wait_for(lambda: call('get_state')['pending']['count'] == 0)
            items = wait_for(lambda: (v if len(v := call('get_queue')) == 2 else None))
            for item in items:
                call('delete_annotation', id=item['id'])
            wait_for(lambda: call('get_queue') == [])
            try:
                call('save_settings', settings='invalid')
                raise AssertionError('Malformed settings accepted')
            except RuntimeError as error:
                assert 'settings:' in str(error)
            try:
                call('does_not_exist')
                raise AssertionError('Unknown command accepted')
            except RuntimeError as error:
                assert 'Unknown command' in str(error)
            process.stdin.close()
            assert process.wait(timeout=5) == 0
            print('Core smoke passed: settings, permissions, hotkeys, routing, capture-to-submit, screenshot, live queue, offline retry, delete, invalid commands, EOF shutdown.')
        finally:
            if process and process.poll() is None:
                process.terminate(); process.wait(timeout=5)
            if server.poll() is None:
                server.terminate(); server.wait(timeout=5)


if __name__ == '__main__':
    main()
