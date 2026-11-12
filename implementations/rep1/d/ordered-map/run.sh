#!/bin/sh
# Run the ordered-map CLI: commands on stdin, results on stdout.
exec "$(dirname "$0")/bin/ordered-map" "$@"
