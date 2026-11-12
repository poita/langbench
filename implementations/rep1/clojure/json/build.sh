#!/bin/sh
# Build the project: AOT-compile the CLI and library into classes/.
# Works from any current directory.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
rm -rf classes
mkdir -p classes
clojure -M:build >&2
