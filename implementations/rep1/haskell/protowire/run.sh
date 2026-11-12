#!/usr/bin/env bash
# Run the protowire CLI: schema + requests on stdin, results on stdout.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/bin/protowire" "$@"
