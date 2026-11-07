"""Repeatable, data-preserving real-library Android startup/scroll probe."""
import argparse
import json
import pathlib
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--adb', required=True)
parser.add_argument('--serial', required=True)
parser.add_argument('--out', required=True)
parser.add_argument('--startup-only', action='store_true')
parser.add_argument('--scroll-only', action='store_true')
parser.add_argument('--folder-only', action='store_true')
args = parser.parse_args()
out = pathlib.Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
package = 'cn.teezy.fluentplayer.standard'
base = [args.adb, '-s', args.serial]

def adb(*command, **kwargs):
    if command[:2] == ('shell', 'input'):
        foreground()
    return subprocess.run(base + list(command), check=True, capture_output=True,
                          **kwargs).stdout.decode('utf-8', errors='replace')

def screenshot(name):
    result = subprocess.run(base + ['exec-out', 'screencap', '-p'],
                            check=True, capture_output=True)
    (out / (name + '.png')).write_bytes(result.stdout)

def foreground():
    state = adb('shell', 'dumpsys', 'activity', 'activities')
    line = next((v for v in state.splitlines() if 'topResumedActivity=' in v), '')
    if package not in line:
        raise RuntimeError('App is no longer foreground; stopped before sending input')

def tap(x, y):
    foreground()
    adb('shell', 'input', 'tap', str(x), str(y))
    time.sleep(1)

def toggle():
    foreground()
    adb('shell', 'input', 'keyevent', '50')  # Existing V view-mode shortcut.
    time.sleep(1.5)

def capture_log(name):
    pid = adb('shell', 'pidof', package).strip().split()[0]
    log = adb('logcat', '-d', '--pid=' + pid, '-v', 'monotonic')
    # Retain only measurements, never library titles or account/network logs.
    lines = [v for v in log.splitlines() if 'FLUENT_PERF ' in v or 'Fluent Player startup ready' in v]
    (out / (name + '-frames.log')).write_text('\n'.join(lines), encoding='utf-8')
    return lines

if not args.scroll_only:
    runs = []
    for cold in [True, False]:
        for repeat in range(10):
            if cold:
                adb('shell', 'am', 'force-stop', package)
            else:
                adb('shell', 'input', 'keyevent', '3')
            time.sleep(.8)
            start = time.monotonic()
            output = adb('shell', 'am', 'start', '-W', '-n', package + '/com.example.video_player_app.MainActivity')
            ready = []
            if cold:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    ready = capture_log('last-startup')
                    if any('"kind":"home"' in line for line in ready):
                        break
                    time.sleep(.2)
                else:
                    raise RuntimeError('No home measurement after cold launch')
            runs.append({'cold': cold, 'repeat': repeat, 'activity': output,
                         'observedReadyMs': (time.monotonic() - start) * 1000,
                         'events': ready})
            (out / 'startup.json').write_text(json.dumps(runs, ensure_ascii=False, indent=2), encoding='utf-8')
            print(('cold' if cold else 'warm') + f' {repeat + 1}/10', flush=True)
            time.sleep(2)
    screenshot('startup-home')

if not args.startup_only:
    for scene in (['folder-list', 'folder-grid'] if args.folder_only else ['home-grid', 'home-list', 'folder-list', 'folder-grid']):
        if scene in ['home-list', 'folder-grid']:
            toggle()
        if scene == 'folder-list':
            if not args.folder_only:
                toggle()  # Return the root to its observed three-column grid.
            # Third folder in the observed first root row. Reset the root
            # scroll using the native drag before entering it.
            for _ in range(12):
                adb('shell', 'input', 'swipe', '880', '430', '880', '1810', '120')
            tap(850, 410)
            toggle()  # Large folder, now in list mode.
        screenshot(scene + '-before')
        for repeat in range(3):
            foreground()
            name = f'{scene}-{repeat + 1}'
            device_trace = f'/data/misc/perfetto-traces/fluent-{name}.perfetto-trace'
            config = '''buffers { size_kb: 16384 fill_policy: RING_BUFFER }
duration_ms: 63000
data_sources { config { name: "android.surfaceflinger.frametimeline" } }
data_sources { config { name: "linux.ftrace" ftrace_config {
  ftrace_events: "sched/sched_switch"
  ftrace_events: "sched/sched_waking"
  atrace_categories: "gfx"
  atrace_categories: "view"
  atrace_apps: "cn.teezy.fluentplayer.standard"
} } }
'''
            adb('shell', 'perfetto', '--background-wait', '--txt', '-c', '-', '-o', device_trace,
                input=config.encode())
            adb('shell', 'log', '-t', 'FLUENT_SCENARIO', 'start-' + name)
            started = time.monotonic()
            count = 0
            while time.monotonic() - started < 60:
                if count % 6 == 0:
                    foreground()
                down = (count // 6) % 2 == 0
                y1, y2 = (1810, 430) if down else (430, 1810)
                adb('shell', 'input', 'swipe', '880', str(y1), '880', str(y2),
                    '350' if count % 3 else '130')
                count += 1
            adb('shell', 'log', '-t', 'FLUENT_SCENARIO', 'end-' + name)
            time.sleep(3.5)
            adb('pull', device_trace, str(out / (name + '.perfetto-trace')))
            capture_log(name)
            (out / (name + '-memory.txt')).write_text(adb('shell', 'dumpsys', 'meminfo', package), encoding='utf-8')
            print(name + f' complete ({count} swipes)', flush=True)
        screenshot(scene + '-after')
    # Restore the original grid mode and return to the root without editing data.
    adb('shell', 'input', 'keyevent', '4')
    screenshot('finished')
