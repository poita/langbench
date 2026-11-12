#!/bin/sh
# Build the project: AOT-compile the command-line tool into classes/.
# Works from any current directory.
set -e
cd "$(dirname "$0")"
rm -rf classes
mkdir -p classes
clojure -P >/dev/null 2>&1 || true
clojure -M:build
