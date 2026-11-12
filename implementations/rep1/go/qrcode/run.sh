#!/bin/sh
# Runs the qrcode command-line tool: queries on stdin, symbols on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/qrcode" "$@"
