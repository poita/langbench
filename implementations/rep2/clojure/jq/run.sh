#!/bin/sh
# Run the jq interpreter: filter on the first line of stdin, JSON document after it.
# Works from any current directory.
dir="$(dirname "$0")"
cd "$dir" || exit 1
exec clojure -M:run
