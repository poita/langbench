#!/bin/sh
# Run the depresolve command: reads stdin, writes stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/depresolve" "$@"
