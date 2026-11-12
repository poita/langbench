#!/bin/sh
# Run protowire: reads a schema and requests on stdin, writes results to stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M:run
