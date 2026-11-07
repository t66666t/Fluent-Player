#!/bin/sh
set -eu
APP_DIR=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
for soname in libmpv.so.2 libmpv.so.1; do
    if [ -f "$APP_DIR/lib/$soname" ]; then
        LIBMPV_LIBRARY_PATH="$APP_DIR/lib/$soname"
        export LIBMPV_LIBRARY_PATH
        break
    fi
done
if [ -z "${LIBMPV_LIBRARY_PATH:-}" ]; then
    printf '%s\n' 'Fluent Player: the bundled libmpv is missing. Please extract the complete package.' >&2
    exit 1
fi
PATH="$APP_DIR/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}"
export PATH
# Every ELF object has its own relative RUNPATH. Avoid exporting a private
# LD_LIBRARY_PATH into the user's browser, desktop helpers or drivers.
if [ "${FLUENT_PLAYER_SOFTWARE_RENDERING:-0}" = 1 ]; then
    LIBGL_ALWAYS_SOFTWARE=1
    export LIBGL_ALWAYS_SOFTWARE
fi
exec "$APP_DIR/fluent-player" "$@"
