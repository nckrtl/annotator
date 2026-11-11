#!/usr/bin/env python3
"""Exercise the real core over its private pipes, with an isolated home and server."""
import http.server
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
            'serverURL': base, 'serverAutoStart': False, 't3Enabled': False, 't3Nudge': True,
            'operatorEnabled': False, 'operatorAutoStart': False,
        }))
        permissions_file = temp / 'permissions.json'
        permissions_file.write_text(json.dumps({'accessibility': True, 'screenRecording': True}))
        helper = temp / 'helper.py'
        helper.write_text('''#!/usr/bin/env python3
import json, sys, uuid
from pathlib import Path

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    command = json.loads(line)
    action = command.get('action')
    if action == 'ping': emit({'type': 'online'})
    if action == 'permissions': emit({'type': 'permissions'} | json.loads(Path(__file__).with_name('permissions.json').read_text()))
    if action == 'fixtureClick': emit({'type': 'clickWhileFrozen', 'x': 5, 'y': 6})
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

        # A fake Operator Local API for caller sessions. `plan` sets each action's reply.
        token_dir = temp / 'Library/Application Support/com.nckrtl.operator'
        token_dir.mkdir(parents=True)
        (token_dir / 'control.json').write_text(json.dumps({'enabled': True, 'token': 'smoke-token'}))
        plan = {'start': (202, {}, 0), 'stop': (200, {'text': 'spoken'}, 0), 'wait': (504, {}, 0), 'cancel': (202, {}, 0)}
        operator_requests = []
        class Operator(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
                action = self.path.rsplit('/', 1)[-1]
                operator_requests.append((self.path, self.headers.get('X-Operator-Token'), body, time.monotonic()))
                status, reply, delay = plan[action]
                time.sleep(delay)
                data = json.dumps(reply).encode()
                self.send_response(status); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            def log_message(self, *args):
                pass
        operator = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Operator)
        threading.Thread(target=operator.serve_forever, daemon=True).start()

        server = start_server()
        process = None
        try:
            environment = os.environ | {'HOME': str(temp), 'ANNOTATOR_HELPER': str(helper),
                'ANNOTATOR_OPERATOR_URL': f'http://127.0.0.1:{operator.server_address[1]}'}
            stderr = (temp / 'core.log').open('w')
            process = subprocess.Popen([str(Path(os.environ.get('CARGO_TARGET_DIR', MAC / 'build/rust')) / 'debug/annotator')], env=environment,
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
            for ax, screen in [(False, False), (True, False), (False, True), (True, True)]:
                permissions = {'accessibility': ax, 'screenRecording': screen}
                permissions_file.write_text(json.dumps(permissions))
                call('menu_opened')
                wait_for(lambda: call('get_state')['permissions'] == permissions)
                assert call('get_permissions') == permissions
            print('PASS menu-open and activation permission refresh, including grant and revocation')
            settings = call('get_settings')
            assert not any(key.startswith('t3') for key in settings), 'Old Conn keys are ignored'
            settings['operatorAutoStart'] = True
            assert call('save_settings', settings=settings)['operatorAutoStart'] is True
            saved = json.loads((settings_dir / 'settings.json').read_text())
            assert saved['operatorAutoStart'] is True and not any(key.startswith('t3') for key in saved)
            assert call('save_projects', routes={'projects': [{'id': 'fixture', 'name': 'Fixture project',
                'root': str(temp), 'bundleIds': ['com.example.fixture'], 'notes': 'Old notes'}]}) is None
            routes = call('get_projects')['routes']['projects']
            project = routes[0]
            assert project['instructions'] == 'Old notes' and 'notes' not in project
            project.update(name='Renamed project', instructions='Run checks', urlPrefixes=[])
            other = dict(project, id='other', name='Other project', bundleIds=['com.example.other'])
            assert call('save_projects', routes={'projects': [other, project]}) is None
            assert call('get_projects')['routes']['projects'] == [other, project]
            assert call('save_projects', routes={'projects': [project, other]}) is None
            assert call('get_projects')['routes']['projects'] == [project, other]
            call('toggle_annotating')
            wait_for(lambda: any(e.get('event') == 'comment-opened' for e in events) or (call('get_state') and False))
            assert not call('get_state')['annotating'], 'Selection must release the screen'
            assert call('get_state')['commentOpen'], 'Selection must preserve the draft'
            call('submit_comment', text='Native bridge smoke test')
            items = wait_for(lambda: call('get_queue'))
            first = items[0]
            assert first['comment'] == 'Native bridge smoke test'
            assert first['native']['project'] == 'Renamed project'
            assert call('save_projects', routes={'projects': [other]}) is None
            assert call('get_projects')['routes']['projects'] == [other]
            assert call('get_queue')[0]['id'] == first['id']
            assert call('get_screenshot', id=first['id']).startswith('data:image/png;')
            assert any(e.get('event') == 'queue' for e in events)
            server.terminate(); server.wait(timeout=5)
            call('toggle_annotating')
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

            # Caller sessions: each comment box owns its sessions; submit and moves never wait.
            settings = call('get_settings'); settings['operatorEnabled'] = True; settings['operatorAutoStart'] = False
            call('save_settings', settings=settings)
            def open_comment(trigger):
                before = len([e for e in events if e.get('event') == 'comment-opened'])
                trigger()
                return wait_for(lambda: (call('get_state') and (opened := [e for e in events if e.get('event') == 'comment-opened'])[before:] and opened[-1]['payload']))
            target = open_comment(lambda: call('toggle_annotating'))
            annotation = target['annotationId']
            assert target['dictation'] == {'autoStart': False} and annotation, target
            session = f'{annotation}-1'
            assert call('operator', action='start', session=session) == {'result': 'ok'}
            assert call('operator', action='wait', session=session) == {'result': 'timedOut'}
            path, token, body, _ = operator_requests[0]
            assert (path, token, body) == ('/dictate/start', 'smoke-token', {'session': session}), operator_requests[0]
            assert operator_requests[1][0] == '/dictate/wait'
            plan['stop'] = (200, {'text': ' spoken words '}, 1.0)
            began = time.monotonic()
            call('submit_comment', text='Typed', session=session)
            assert time.monotonic() - began < 0.5, 'Submit must not wait for the transcript'
            assert not call('get_state')['commentOpen'], 'Submit must close the panel at once'
            item = wait_for(lambda: next((i for i in call('get_queue') if i['id'] == annotation), None))
            assert item['comment'] == 'Typed spoken words'
            assert operator_requests[-1][:3] == ('/dictate/stop', 'smoke-token', {'session': session})
            print('PASS submit hands the live session to the core; the transcript joins the typed text in the background')

            # A move hands off and opens the next comment while the earlier session still transcribes.
            first = open_comment(lambda: call('toggle_annotating'))
            assert call('operator', action='start', session=f"{first['annotationId']}-1") == {'result': 'ok'}
            plan['stop'] = (200, {'text': 'moved'}, 1.5)
            call('helper', command={'action': 'fixtureClick'})
            wait_for(lambda: call('get_state') and any(e.get('event') == 'comment-finish' for e in events))
            began = time.monotonic()
            second = open_comment(lambda: call('comment_finish_done', text='', session=f"{first['annotationId']}-1"))
            assert time.monotonic() - began < 1.0 and second['annotationId'] != first['annotationId'], 'A move must not wait'
            assert call('get_state')['commentOpen']
            assert call('operator', action='start', session=f"{second['annotationId']}-1") == {'result': 'ok'}
            item = wait_for(lambda: next((i for i in call('get_queue') if i['id'] == first['annotationId']), None))
            assert item['comment'] == 'moved'
            print('PASS a move opens the next comment and starts its session while the earlier one transcribes')

            # A lost background transcript posts the typed text and shows a notice without comment text.
            plan['stop'] = (409, {'error': 'Dictation cancelled'}, 0)
            call('submit_comment', text='Kept typed text', session=f"{second['annotationId']}-1")
            message = wait_for(lambda: call('get_state')['dictationError'])
            assert 'Fixture · Save' in message and 'Operator cancelled it' in message and 'Kept typed text' not in message, message
            item = wait_for(lambda: next((i for i in call('get_queue') if i['id'] == second['annotationId']), None))
            assert item['comment'] == 'Kept typed text'
            call('dismiss_dictation_error')
            assert call('get_state')['dictationError'] is None
            third = open_comment(lambda: call('toggle_annotating'))
            call('submit_comment', text='', session=f"{third['annotationId']}-1")
            message = wait_for(lambda: call('get_state')['dictationError'])
            assert message.endswith('Nothing was sent.'), message
            plan['stop'] = (200, {'text': ''}, 0)
            fourth = open_comment(lambda: call('toggle_annotating'))
            call('submit_comment', text='', session=f"{fourth['annotationId']}-1")
            wait_for(lambda: call('get_state')['dictationError'] is None)
            time.sleep(0.3)
            assert not any(i['id'] in (third['annotationId'], fourth['annotationId']) for i in call('get_queue')), 'Empty comments must not post'
            try:
                call('submit_comment', text=' ')
                raise AssertionError('An empty comment without a session was accepted')
            except RuntimeError as error:
                assert 'Write a comment first' in str(error)
            for item in call('get_queue'):
                call('delete_annotation', id=item['id'])
            print('PASS a lost transcript posts typed text and shows a notice; empty results post nothing')
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
            call('toggle_annotating')
            time.sleep(0.2)
            call('cancel_comment')
            assert not call('get_state')['annotating'], 'Escape must not resume the overlay'
            assert not call('get_state')['commentOpen'], 'Escape must close the draft'
            process.stdin.close()
            assert process.wait(timeout=5) == 0
            print('Core smoke passed: settings, permissions, hotkeys, project CRUD and priority, routing, capture-to-submit, screenshot, live queue, offline retry, delete, invalid commands, EOF shutdown.')
        finally:
            if process and process.poll() is None:
                process.terminate(); process.wait(timeout=5)
            if server.poll() is None:
                server.terminate(); server.wait(timeout=5)
            operator.shutdown()


if __name__ == '__main__':
    main()
