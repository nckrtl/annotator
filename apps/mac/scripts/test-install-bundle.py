#!/usr/bin/env python3
"""Exercise replacement and signing refusal in isolated bundles, with no OS registration."""
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

MAC = Path(__file__).resolve().parents[1]


def run_case(failure=None):
    with tempfile.TemporaryDirectory(dir=MAC / 'build', prefix='install-test-') as directory:
        root = Path(directory)
        source = root / 'built/Annotator.app'
        installed = root / 'Applications/Annotator.app'
        backup = root / 'Backups/Previous.zip'
        log = root / 'registrations'
        binaries = root / 'bin'
        binaries.mkdir()
        for app, version in [(source, 'new'), (installed, 'old')]:
            (app / 'Contents/Helpers/AnnotatorNative.app').mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            (app / 'Contents/Resources/annotator-core').write_text(version)
            (app / 'version').write_text(version)
        (binaries / 'codesign').write_text("""#!/usr/bin/env python3
import os, sys
path = sys.argv[-1]
if '-r-' in sys.argv:
    identity = 'stable'
    if '/built/' in path and path.endswith(os.environ.get('MISMATCH', 'no-match')):
        identity = 'changed'
    print('designated => identifier "' + identity + '"')
if '--verify' in sys.argv and '/Applications/' in path and os.environ.get('FAIL_VERIFY'):
    sys.exit(1)
""")
        (binaries / 'lsregister').write_text("""#!/usr/bin/env python3
import os, sys
with open(os.environ['REGISTRATION_LOG'], 'a') as log:
    print(' '.join(sys.argv[1:]), file=log)
""")
        for executable in binaries.iterdir():
            executable.chmod(0o755)
        env = os.environ | {'PATH': str(binaries) + ':' + os.environ['PATH'],
            'ANNOTATOR_LSREGISTER': str(binaries / 'lsregister'), 'REGISTRATION_LOG': str(log)}
        if failure == 'copy':
            env['FAIL_VERIFY'] = '1'
        elif failure:
            env['MISMATCH'] = failure
        result = subprocess.run(['bash', str(MAC / 'scripts/install-bundle.sh'), str(source),
            str(installed), str(backup)], env=env, capture_output=True, text=True)
        assert (result.returncode != 0) == bool(failure), result.stderr
        if failure and failure != 'copy':
            assert not backup.exists() and not log.exists(), 'Must refuse before archive or unregister'
            assert (installed / 'version').read_text() == 'old'
        else:
            with zipfile.ZipFile(backup) as archive:
                assert archive.read('Annotator.app/version') == b'old'
            expected = 'old' if failure else 'new'
            assert (installed / 'version').read_text() == expected
            lines = log.read_text().splitlines()
            assert lines[-2:] == ['-f ' + str(installed / 'Contents/Helpers/AnnotatorNative.app'), '-f ' + str(installed)]
            assert '-u ' + str(source) in lines
            assert '-u ' + str(source / 'Contents/Helpers/AnnotatorNative.app') in lines
            assert list((root / 'Backups').iterdir()) == [backup], 'No discoverable backup bundle'
        print('PASS installer ' + (failure or 'replacement and ZIP backup'))


if __name__ == '__main__':
    (MAC / 'build').mkdir(exist_ok=True)
    for failure in [None, 'Annotator.app', 'AnnotatorNative.app', 'annotator-core', 'copy']:
        run_case(failure)
