"""Select a local sample in the real GTK dialog while native Flutter tests run."""
from pathlib import Path
import subprocess
import sys
import threading
import time

sample = Path(sys.argv[1]).resolve()
selected = threading.Event()


def choose():
    for _ in range(2400):
        if selected.is_set():
            return
        result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^Fluent file dialog smoke$'],
                                capture_output=True, text=True)
        if result.returncode == 0:
            window = result.stdout.splitlines()[0]
            print('GTK chooser appeared; selecting ' + str(sample), flush=True)
            time.sleep(1)
            subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+l'], check=True)
            subprocess.run(['xdotool', 'type', '--clearmodifiers', str(sample)], check=True)
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'Return'], check=True)
            # The location entry may first resolve the path asynchronously.
            # Activate the actual Open button if the chooser is still visible.
            time.sleep(1)
            visible = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name',
                                      '^Fluent file dialog smoke$'], capture_output=True)
            if visible.returncode == 0:
                subprocess.run(['/usr/bin/python3', 'tool/linux_window_probe.py', window,
                                '.artifacts/linux-smoke/file-chooser.png'], check=False)
                subprocess.run(['/usr/bin/python3', 'tool/linux_gtk_picker_driver.py', str(sample)],
                               check=True, timeout=25)
            print('GTK file selection submitted', flush=True)
            selected.set()
            return
        time.sleep(0.5)


thread = threading.Thread(target=choose, daemon=True)
thread.start()
result = subprocess.run(['flutter', 'test', 'integration_test/linux_runtime_test.dart', '-d', 'linux'],
                        timeout=1200)
if result.returncode == 0 and not selected.is_set():
    raise RuntimeError('The native GTK chooser was never exercised')
selected.set()
raise SystemExit(result.returncode)
