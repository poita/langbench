#!/bin/sh
# Runs the protowire CLI: schema and requests on stdin, results on stdout.
exec "$(cd "$(dirname "$0")" && pwd)/bin/protowire" "$@"
