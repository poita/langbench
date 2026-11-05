#!/bin/sh
# Run the inflate CLI: hex DEFLATE stream on stdin, hex result (or "error") on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/inflate" "$@"
