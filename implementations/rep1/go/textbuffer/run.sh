#!/bin/sh
# Runs the textbuffer CLI: script on stdin, output on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/textbuffer" "$@"
