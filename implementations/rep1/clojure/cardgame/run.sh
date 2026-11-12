#!/bin/sh
# Run the cardgame CLI: match file on stdin, log on stdout.  Works from any
# current directory (the card database path in the match file is resolved
# against the current directory, as SPEC.md requires).
dir=$(cd "$(dirname "$0")" && pwd)
exec java -cp "$(cat "$dir/target/classpath")" cardgame.cli
