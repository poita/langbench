#!/bin/sh
# Runs the minisql CLI: SQL script on stdin, SELECT results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/minisql" "$@"
