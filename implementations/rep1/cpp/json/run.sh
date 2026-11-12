#!/bin/sh
# Run the CLI: JSON on stdin, canonical form (or "invalid") on stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/jsoncanon" "$@"
