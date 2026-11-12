#!/bin/sh
# Builds chess-perft: ahead-of-time compiles the CLI into classes/ so that
# run.sh starts quickly. Works from any current directory.
set -e
cd "$(dirname "$0")"
rm -rf classes
mkdir -p classes
clojure -M -e "(compile 'chess-perft.cli)"
