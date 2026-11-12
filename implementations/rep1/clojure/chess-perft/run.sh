#!/bin/sh
# Runs the chess-perft CLI: queries on stdin, results on stdout.
# Works from any current directory.
cd "$(dirname "$0")" || exit 1
exec clojure -M -m chess-perft.cli
