"""Exercise relocated loader paths, media CLIs, mpv and a real GTK cold start."""
import argparse
import ctypes
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

from linux_bundle import audit

ROOT = Path(__file__).resolve().parents[1]


def mpv_decode(app, sample):
    libraries = list((app / 'lib').glob('libmpv.so.[12]'))
    if len(libraries) != 1:
        raise ValueError('A bundle must contain exactly one matching libmpv ABI')
    library = ctypes.CDLL(str(libraries[0]))
    library.mpv_create.restype = ctypes.c_void_p
    library.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    library.mpv_initialize.argtypes = [ctypes.c_void_p]
    library.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
    library.mpv_get_property.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
    library.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
    handle = library.mpv_create()
    if not handle:
        raise RuntimeError('mpv_create failed')
    try:
        for key, value in ((b'vo', b'null'), (b'ao', b'null'), (b'hwdec', b'no'), (b'idle', b'yes')):
            if library.mpv_set_option_string(handle, key, value) < 0:
                raise RuntimeError('mpv option failed: ' + key.decode())
        if library.mpv_initialize(handle) < 0:
            raise RuntimeError('mpv_initialize failed')
        command = (ctypes.c_char_p * 4)(b'loadfile', os.fsencode(sample), b'replace', None)
        if library.mpv_command(handle, command) < 0:
            raise RuntimeError('mpv loadfile failed')
        duration = ctypes.c_double()
        for _ in range(100):
            if library.mpv_get_property(handle, b'duration', 5, ctypes.byref(duration)) >= 0 and duration.value > 0:
                return
            time.sleep(0.05)
        raise RuntimeError('mpv did not decode the generated sample')
    finally:
        library.mpv_terminate_destroy(handle)


def gui(app, report):
    report.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='fluent-cold-home-') as temporary:
        runtime = Path(temporary) / 'runtime'
        runtime.mkdir(mode=0o700)
        env = os.environ.copy()
        env.update(HOME=temporary, XDG_DATA_HOME=temporary + '/data', XDG_CONFIG_HOME=temporary + '/config',
                   XDG_CACHE_HOME=temporary + '/cache', XDG_RUNTIME_DIR=str(runtime),
                   GDK_BACKEND='x11', LIBGL_ALWAYS_SOFTWARE='1')
        env.pop('LD_LIBRARY_PATH', None)
        env.pop('LD_PRELOAD', None)
        log = report / 'cold-start.log'
        with log.open('wb') as stream:
            process = subprocess.Popen([str(app / 'fluent-player.sh')], env=env,
                                       stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                window = None
                for _ in range(180):
                    if process.poll() is not None:
                        raise RuntimeError('Application exited during cold start: ' + log.read_text(errors='replace'))
                    result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(process.pid)],
                                            text=True, capture_output=True)
                    if result.returncode == 0 and 'Fluent Player startup ready' in log.read_text(errors='replace'):
                        window = result.stdout.splitlines()[0]
                        break
                    time.sleep(0.25)
                if window is None:
                    raise RuntimeError('Application never reached its interactive first frame; see ' + str(log))
                for index, size in enumerate(((1280, 720), (1920, 1176), (800, 600))):
                    subprocess.run(['xdotool', 'windowsize', window, *map(str, size)], check=True)
                    time.sleep(4)
                    if process.poll() is not None:
                        raise RuntimeError('Application crashed during window resize')
                    subprocess.run(['/usr/bin/python3', str(ROOT / 'tool/linux_window_probe.py'), window,
                                    str(report / f'frame-{index}.png')], check=True)
                text = log.read_text(errors='replace')
                if re.search(r'App startup initialization failed|Timed out waiting for OpenGL frame|'
                             r'Fatal glibc|SIGSEGV|SIGABRT|MediaPlaybackService init failed', text):
                    raise RuntimeError('Cold-start log contains a runtime failure; see ' + str(log))
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()


def smoke(app, report):
    audit(app)
    for name in ('ffmpeg', 'ffprobe'):
        subprocess.run([str(app / 'bin' / name), '-version'], check=True, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix='fluent-media-probe-') as temporary:
        sample = Path(temporary) / 'sample with sound.mkv'
        subprocess.run([str(app / 'bin/ffmpeg'), '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                        'testsrc2=size=320x180:rate=5', '-f', 'lavfi', '-i', 'sine=frequency=440',
                        '-t', '2', '-c:v', 'mpeg4', '-c:a', 'aac', str(sample)], check=True)
        subprocess.run([str(app / 'bin/ffprobe'), '-v', 'error', '-show_entries', 'format=duration',
                        '-of', 'json', str(sample)], check=True)
        mpv_decode(app, sample)
    subprocess.run(['xvfb-run', '-a', '-s', '-screen 0 1920x1200x24', 'dbus-run-session', '--',
                    sys.executable, str(Path(__file__).resolve()), '--gui', '--bundle', str(app),
                    '--report', str(report)], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--gui', action='store_true')
    args = parser.parse_args()
    (gui if args.gui else smoke)(args.bundle.resolve(), args.report.resolve())
