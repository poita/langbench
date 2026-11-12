#!/bin/sh
# Run the CLI: JSON document on stdin, canonical form (or "invalid") on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/bin/json-canon" "$@"
