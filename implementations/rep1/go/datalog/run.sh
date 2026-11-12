#!/bin/sh
# Runs the datalog CLI: program on stdin, answers on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/datalog" "$@"
