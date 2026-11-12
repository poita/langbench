#!/bin/sh
# Runs the ordered-map binary: commands on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/ordered-map" "$@"
