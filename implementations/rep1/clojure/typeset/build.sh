#!/bin/sh
# Build the project: fetch dependencies and AOT-compile the command-line tool.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
mkdir -p classes
clojure -P
clojure -M -e "(compile 'typeset.cli)"
