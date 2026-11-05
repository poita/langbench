#!/bin/sh
# Run the textbuffer command-line tool: script on stdin, output on stdout.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/bin/textbuffer" "$@"
