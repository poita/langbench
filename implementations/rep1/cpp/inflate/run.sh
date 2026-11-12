#!/bin/sh
# Run the CLI: hex DEFLATE stream on stdin, hex output (or "error") on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/inflate" "$@"
