#!/bin/sh
# Run the cardgame tool: match file on stdin, log on stdout.
exec "$(dirname "$0")/bin/cardgame" "$@"
