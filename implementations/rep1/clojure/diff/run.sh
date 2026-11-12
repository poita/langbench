#!/bin/sh
# Runs the diff/patch CLI: reads stdin, writes stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M -m diff.main
