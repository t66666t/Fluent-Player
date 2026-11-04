#!/bin/sh
set -eu
APP_DIR=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
case "$DATA_HOME" in
    /*) ;;
    *) DATA_HOME="$HOME/.local/share" ;;
esac
mkdir -p "$DATA_HOME/applications"
# Desktop Entry Exec quoting is not shell quoting. Escape reserved characters
# and literal percent signs instead of evaluating a user-controlled path.
escaped=$(printf '%s' "$APP_DIR" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g; s/%/%%/g')
{
    printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Fluent Player'
    printf 'Exec="%s/fluent-player.sh"\n' "$escaped"
    printf 'Icon=%s/fluent-player.png\n' "$APP_DIR"
    printf '%s\n' 'Terminal=false' 'Categories=AudioVideo;Player;' 'StartupWMClass=io.github.t66666t.FluentPlayer'
} > "$DATA_HOME/applications/io.github.t66666t.FluentPlayer.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DATA_HOME/applications"
fi
printf '%s\n' 'Fluent Player was added to the current user application menu.'
