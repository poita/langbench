#!/bin/sh
# Run the qrcode CLI: queries on stdin, symbols on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
bin="$(cd "$dir" && cabal list-bin -v0 exe:qrcode)" || exit 1
exec "$bin" "$@"
