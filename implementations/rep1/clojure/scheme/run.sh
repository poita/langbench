#!/bin/sh
# Read a Scheme program on stdin, write its output on stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M -m scheme.main "$@"
