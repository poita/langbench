#!/bin/sh
# Run the CLI: reads operations on stdin, writes results on stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/softfloat_cli" "$@"
