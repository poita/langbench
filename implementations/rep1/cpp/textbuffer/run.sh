#!/bin/sh
# Runs the command-line tool: document and commands on stdin, output on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/textbuffer-cli" "$@"
