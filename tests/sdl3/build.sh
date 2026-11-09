#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ -d sdl3/vendor/include ]; then
    exec "${REDUB:-redub}" build "$@"
fi
exec "${REDUB:-redub}" build --force "$@"
