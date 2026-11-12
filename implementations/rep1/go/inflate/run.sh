#!/bin/sh
# Run the inflate command: hex on stdin, hex (or "error") on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/inflate" "$@"
