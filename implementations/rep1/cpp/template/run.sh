#!/bin/sh
# Runs the CLI: template document on stdin, rendered output on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/jinjalite" "$@"
