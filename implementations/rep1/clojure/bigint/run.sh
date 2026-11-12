#!/bin/sh
# Runs the bigint CLI: queries on stdin, results on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
exec java -cp "$(cat "$dir/target/classpath")" bigint.cli
