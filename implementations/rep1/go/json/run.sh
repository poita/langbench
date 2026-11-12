#!/bin/sh
# Run the jsoncanon tool: JSON document on stdin, canonical form on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/jsoncanon" "$@"
