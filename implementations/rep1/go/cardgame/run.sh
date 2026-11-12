#!/bin/sh
# Run the cardgame binary: match file on stdin, log on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/cardgame" "$@"
