#!/bin/sh
# Build: fetch/resolve dependencies and AOT-compile the command-line tool into
# classes/ so that start-up does not have to compile the sources again.
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -M -e "(compile 'rubiks.cli)"
