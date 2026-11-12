#!/bin/sh
# Runs the CLI: queries on stdin, symbols on stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir" || exit 1
exec clojure -M:run
