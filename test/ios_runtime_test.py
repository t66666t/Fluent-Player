"""Host verification of packaged Python and downloader; not an iOS device test.

Prepare with python tool/prepare_ios_runtime.py --packages-only. The optional
EJS replay uses the official player and QuickJS CLI in .artifacts, never ships
the host CLI and never invokes a subprocess from the production Python code.
"""
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'packages/ios_ytdlp/ios/Vendor'
sys.path.insert(0, str(VENDOR / 'site-packages'))
native = types.ModuleType('_fluent_native')
native.emit = lambda *args: None
native.is_cancelled = lambda task: False
sys.modules['_fluent_native'] = native
import fluent_ios_runtime as runtime
import fluent_jsc as jsc


class RuntimeTests(unittest.TestCase):
    def test_build_inputs_match_pinned_checksums(self):
        manifest = json.loads((VENDOR.parent.parent / 'runtime.lock.json').read_text())
        for artifact in [manifest['quickjs'], *manifest['wheels']]:
            path = VENDOR / 'cache' / artifact['url'].rsplit('/', 1)[1]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), artifact['sha256'])
        self.assertEqual(jsc.YTDLP_VERSION, '2026.10.21')
        self.assertEqual(jsc.EJS_VERSION, '0.8.0')

    def test_missing_or_external_bridge_fails_before_extraction(self):
        for proxy in ['', 'http://proxy.invalid:7890', 'http://u:p@127.0.0.1:7890', 'socks5://127.0.0.1:1080']:
            with self.assertRaises(ValueError):
                runtime.resolve('https://example.invalid/video', json.dumps({'useProxy': True, 'proxy': proxy}))

    def test_pause_and_resume_retains_partial_and_reproduces_complete_bytes(self):
        self._resume_case()

    def test_changed_remote_file_restarts_the_affected_file(self):
        self._resume_case(change_remote=True)

    def test_corrupted_local_partial_restarts_the_affected_file(self):
        self._resume_case(corrupt_local=True)

    def test_weak_remote_validator_restarts_the_affected_file(self):
        self._resume_case(weak_validator=True)

    def test_standalone_no_continue_restarts_unverified_changed_partial(self):
        self._resume_case(change_remote=True, standalone_restart=True)

    def _resume_case(self, change_remote=False, corrupt_local=False, weak_validator=False, standalone_restart=False):
        content = bytes(range(256)) * 8192
        ranges = []
        def etag():
            value = '"' + hashlib.sha256(content).hexdigest() + '"'
            return 'W/' + value if weak_validator else value

        class Proxy(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_HEAD(self):
                self.send_response(200)
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Content-Length', len(content))
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('ETag', etag())
                self.end_headers()

            def do_GET(self):
                self.assert_origin()
                range_value = self.headers.get('Range')
                start = int(range_value.split('=')[1].split('-')[0]) if range_value else 0
                ranges.append(start)
                self.send_response(206 if range_value else 200)
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Content-Length', len(content) - start)
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('ETag', etag())
                if range_value:
                    self.send_header('Content-Range', f'bytes {start}-{len(content)-1}/{len(content)}')
                self.end_headers()
                try:
                    self.wfile.write(content[start:])
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def assert_origin(self):
                if not self.path.startswith('http://origin.invalid/'):
                    raise AssertionError('Downloader bypassed the supplied bridge')

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        interrupted = False
        events = []

        def emit(task, payload):
            nonlocal interrupted
            event = json.loads(payload)
            events.append(event)
            if event['type'] == 'task_progress' and event.get('downloadedBytes', 0) > 0:
                interrupted = True

        try:
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'test.%(ext)s'
                args = ['--ignore-config', '--proxy', f'http://127.0.0.1:{server.server_port}',
                        '--continue', '--no-playlist', '--no-warnings', '-o', str(output),
                        'http://origin.invalid/video.mp4']
                request = json.dumps({'taskId': 'one', 'url': args[-1], 'outputDir': directory,
                                     'outputTemplate': output.name, 'args': args})
                with patch.object(native, 'emit', emit), patch.object(native, 'is_cancelled', lambda task: interrupted):
                    result = json.loads(runtime.download(request))
                self.assertEqual(result['exitCode'], 130, events)
                partials = list(Path(directory).glob('*.part'))
                self.assertTrue(partials, 'Interrupted downloads must retain their partial file')
                self.assertGreater(partials[0].stat().st_size, 0)
                if change_remote:
                    content = bytes(reversed(range(256))) * 8192
                if corrupt_local:
                    with partials[0].open('r+b') as corrupt:
                        corrupt.write(b'corrupted retained bytes')
                ranges.clear()
                interrupted = False
                if standalone_restart:
                    # The desktop CLI has no embedded verification hook. Exercise
                    # its real CLI option parsing and downloader against changed
                    # remote bytes with a retained partial, without our validator.
                    import yt_dlp_bridge
                    args[args.index('--continue')] = '--no-continue'
                    args.insert(0, '--no-force-overwrites')
                    standalone = json.loads(request)
                    standalone['args'] = args
                    result = json.loads(yt_dlp_bridge.download(json.dumps(standalone)))
                else:
                    with patch.object(native, 'is_cancelled', lambda task: False):
                        result = json.loads(runtime.download(request))
                self.assertEqual(result['exitCode'], 0, result)
                self.assertEqual(hashlib.sha256((Path(directory) / 'test.mp4').read_bytes()).digest(),
                                 hashlib.sha256(content).digest())
                if change_remote or corrupt_local or weak_validator:
                    self.assertFalse(any(start > 0 for start in ranges), ranges)
                else:
                    self.assertTrue(any(start > 0 for start in ranges), ranges)
                self.assertFalse(list(Path(directory).glob('*.part')))
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_ejs_official_n_and_signature_vectors_with_quickjs(self):
        executable = ROOT / '.artifacts/ios-runtime-inspect/qjs.exe'
        player = ROOT / '.artifacts/ios-runtime-inspect/player-74edf1a3.js'
        if not executable.exists() or not player.exists():
            self.skipTest('Official player/host QuickJS replay fixtures not prepared')

        def execute(script):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'challenge.js'
                path.write_text(script, encoding='utf-8')
                return subprocess.run([str(executable), '--memory-limit', '134217728', '--stack-size', '1048576', str(path)],
                                      capture_output=True, text=True, check=True, timeout=30).stdout

        signature = 'NJAJEij0EwRgIhAI0KExTgjfPk-MPM9MAdzyyPRt=BM8-XO5tm5hlMCSVpAiEAv7eP3CURqZNSPow8BXXAoazVoXgeMP7gH9BdylHCwgw=gwzz'
        with patch.object(native, 'run_js', execute, create=True):
            result = jsc.solve(player.read_text(encoding='utf-8'), [
                {'type': 'n', 'challenges': ['IlLiA21ny7gqA2m4p37', 'eabGF/ps%UK=uWHXGh6FR4']},
                {'type': 'sig', 'challenges': [signature]}])
        self.assertEqual(result[0]['data']['IlLiA21ny7gqA2m4p37'], '9nRTxrbM1f0yHg')
        self.assertEqual(result[0]['data']['eabGF/ps%UK=uWHXGh6FR4'], 'LACmqlhaBpiPlgE-a')
        self.assertEqual(result[1]['data'][signature], signature.replace('tm5hlM', 'tm5hzM')[:-1] + 'l')

    def test_framework_packaging_and_path_boundaries(self):
        spec = importlib.util.spec_from_file_location('runtime_installer', ROOT / 'tool/install_ios_runtime.py')
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            vendor, build = base / 'package/ios/Vendor', base / 'build'
            app = build / 'Runner.app'
            app.mkdir(parents=True)
            source = vendor / 'Python.xcframework/ios-arm64/lib-arm64/python3.13/lib-dynload'
            source.mkdir(parents=True)
            (source / '_ssl.abi3.so').write_bytes(b'test-extension')
            (vendor / 'Python.xcframework/lib/python3.13').mkdir(parents=True)
            (vendor / 'Python.xcframework/lib/python3.13/LICENSE.txt').write_text('PSF test license')
            (vendor / 'site-packages').mkdir()
            (vendor / 'LICENSE-QuickJS-NG.txt').write_text('test license')
            (vendor / 'prepared.json').write_text('{}')
            (base / 'package/runtime.lock.json').write_text('{}')
            environment = {'CODESIGNING_FOLDER_PATH': str(app), 'TARGET_BUILD_DIR': str(build),
                           'ARCHS': 'arm64', 'CODE_SIGNING_ALLOWED': 'NO'}
            with patch.object(installer, 'VENDOR', vendor):
                installer.install(environment)
            marker = app / 'python/lib/python3.13/lib-dynload/_ssl.abi3.fwork'
            self.assertEqual(marker.read_text().strip(), str(Path('Frameworks/_ssl.framework/_ssl')))
            self.assertEqual((app / 'Frameworks/_ssl.framework/_ssl.origin').read_text().strip(), str(marker.relative_to(app)))
            self.assertFalse(list((app / 'python').rglob('*.so')))
            self.assertEqual((app / 'fluent-runtime-licenses/LICENSE-Python.txt').read_text(), 'PSF test license')
            with self.assertRaises(ValueError):
                installer.install({**environment, 'CODESIGNING_FOLDER_PATH': str(base / 'outside.app')})


if __name__ == '__main__':
    unittest.main()
