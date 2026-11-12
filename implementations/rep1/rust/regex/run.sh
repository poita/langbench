#!/bin/sh
# Run the CLI: reads the problem input on stdin, writes results to stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
exec "$dir/target/release/btregex" "$@"
