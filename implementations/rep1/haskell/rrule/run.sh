#!/bin/sh
# Run the rrule command-line tool: stdin -> stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/bin/rrule" "$@"
