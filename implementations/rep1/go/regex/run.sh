#!/bin/sh
# Runs the regexbt tool: reads the batch format on stdin, writes results to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/regexbt" "$@"
