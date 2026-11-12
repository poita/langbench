#!/bin/sh
# Run the protowire CLI: reads stdin, writes stdout.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/build/protowire" "$@"
