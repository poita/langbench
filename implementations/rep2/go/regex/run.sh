#!/bin/sh
# Run the regexvm command: patterns and subjects on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/regexvm" "$@"
