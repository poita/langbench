#!/bin/sh
# Run the regex command: patterns/subjects on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/regex" "$@"
