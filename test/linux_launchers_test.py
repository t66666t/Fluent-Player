"""Exercise shell quoting with stubs and an isolated desktop directory."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
if BASH is None and os.name == 'nt' and shutil.which('git'):
    candidate = Path(shutil.which('git')).parent.parent / 'bin/bash.exe'
    if candidate.is_file():
        BASH = str(candidate)


def shell_path(path):
    if os.name != 'nt':
        return str(path)
    return subprocess.check_output([BASH, '-c', 'cygpath -u "$1"', 'probe', str(path)],
                                   text=True, encoding='utf-8').strip()


@unittest.skipUnless(BASH, 'A POSIX shell is needed for launcher execution')
class LinuxLaunchersTests(unittest.TestCase):
    def fixture(self, root):
        app = root / "app with ' spaces $ and % 字幕"
        (app / 'lib').mkdir(parents=True)
        for name in ('fluent-player.sh', 'install-desktop.sh'):
            shutil.copy2(ROOT / 'packaging/linux' / name, app / name)
        env = os.environ.copy()
        env.pop('BASH_ENV', None)
        env.pop('LIBMPV_LIBRARY_PATH', None)
        env.pop('LD_LIBRARY_PATH', None)
        env['XDG_DATA_HOME'] = shell_path(root / 'desktop')
        return app, env

    def test_launcher_pins_mpv_and_preserves_argument_boundaries_without_global_ld_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, env = self.fixture(root)
            (app / 'lib/libmpv.so.2').write_bytes(b'not an ELF: shell protocol fixture only')
            stub = app / 'video_player_app'
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$LIBMPV_LIBRARY_PATH" "$1" "${LD_LIBRARY_PATH-unset}"\n',
                            encoding='utf-8', newline='\n')
            stub.chmod(0o755)
            argument = "media with ' $ and spaces.mkv"
            text = subprocess.check_output([BASH, str(app / 'fluent-player.sh'), argument],
                                           env=env, text=True, encoding='utf-8').splitlines()
            self.assertEqual(text, [shell_path(app / 'lib/libmpv.so.2'), argument, 'unset'])

    def test_desktop_installer_escapes_field_codes_and_writes_only_the_requested_user_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, env = self.fixture(root)
            subprocess.run([BASH, str(app / 'install-desktop.sh')], env=env,
                           check=True, stdout=subprocess.DEVNULL)
            text = (root / 'desktop/applications/io.github.t66666t.FluentPlayer.desktop').read_text(encoding='utf-8')
            self.assertIn('StartupWMClass=io.github.t66666t.FluentPlayer', text)
            self.assertIn('%%', text)
            self.assertIn(r'\$', text)
            self.assertIn('Exec="', text)


if __name__ == '__main__':
    unittest.main()
