#!/bin/sh
# Builds the project: AOT-compiles the command-line tool into classes/ so that
# run.sh starts quickly.  Works from any current directory.
set -e
cd "$(dirname "$0")"
rm -rf classes
mkdir -p classes
clojure -M:compile
