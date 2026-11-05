#!/bin/sh
# Runs the cardgame tool: match file on stdin, event log on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/cardgame" "$@"
