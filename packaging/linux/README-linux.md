# Fluent Player on Linux

Use the package whose filename matches your distribution and CPU. These builds
target **x86-64**: Ubuntu 22.04 / 24.04 and Debian 12 / 13. A build for one
distribution is not claimed to work on another. ARM64 and musl distributions
need their own compatible native dependencies and validation.

## Install

For DEB, install the matching file with `sudo apt install ./FluentPlayer-….deb`.
APT supplies libc, C++ and graphics driver libraries for that distribution.

For tar.gz, extract the **entire** directory and run `./fluent-player.sh`.
Optionally run `./install-desktop.sh` to add it to your own application menu.
Keep the directory in its installed location after adding the menu shortcut.

The program includes the matching **libmpv and its dependency tree**, FFmpeg,
ffprobe, Flutter plugins and isolated media helpers. `linux-runtime.json`
records the system package versions used; third-party notices are in `licenses`.
The launcher selects the bundled mpv and CLI tools; it does not replace system
libraries or inject private libraries into Chrome.

## Desktop services

- A graphical GTK 3 desktop and working OpenGL/Mesa drivers are required.
- File import and data-directory recovery use a native GTK chooser; a portal
  file chooser is not required.
- Web discovery / official web login requires an installed Chrome or Chromium.
  A browser is not silently downloaded or bundled with this package.
- A user D-Bus session and an unlocked Secret Service keyring (for example
  GNOME Keyring) are needed to persist account secrets. No plaintext fallback
  is enabled when a keyring is unavailable.
- Audio output requires a working sound device and desktop audio service.

## Troubleshooting

Start from a terminal with `./fluent-player.sh` to capture diagnostics. For a
VM without hardware graphics, try
`FLUENT_PLAYER_SOFTWARE_RENDERING=1 ./fluent-player.sh`; this still needs Mesa's
software OpenGL implementation. Do not replace libmpv with a different ABI or
rename libmpv.so.2 to libmpv.so.1.

When old data directories conflict, select the intended library on the recovery
screen, or enter its full path. Files are neither merged nor deleted. Changing
the application ID preserves old settings and registered data locations.

Packaging and automated checks are not a substitute for validating real GPUs,
Wayland/X11, audio, playback and upgrades on the target machine. Report the
distribution, display backend and terminal logs when requesting help.
