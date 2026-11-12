#!/bin/sh
# Run the CLI: operations on stdin, results on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir" || exit 1
exec java -cp "$(cat classes/classpath.txt)" softfloat.cli
