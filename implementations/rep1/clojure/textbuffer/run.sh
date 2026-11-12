#!/bin/sh
# Runs the textbuffer CLI: document and commands on stdin, output on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir" || exit 1
exec clojure -M -m textbuffer.cli
