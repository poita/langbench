#!/bin/sh
# Run the protowire CLI: schema and requests on stdin, results on stdout.
exec "$(dirname "$0")/bin/protowire" "$@"
