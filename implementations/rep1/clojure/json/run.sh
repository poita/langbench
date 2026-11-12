#!/bin/sh
# Run the canonicalizer: reads one JSON document on stdin, writes one line.
# Works from any current directory.
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir" || exit 1
exec clojure -M:aot -m json.cli
