#!/bin/sh
# Run the CLI: reads the mode line and document on stdin, writes stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
exec "$dir/target/release/tomlcodec" "$@"
