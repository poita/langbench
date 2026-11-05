#!/bin/sh
# Run the ordered-map CLI: commands on stdin, answers on stdout.
exec "$(dirname "$0")/ordered-map" "$@"
