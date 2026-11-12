#!/usr/bin/env bash
# Build the project: AOT-compile the command line tool into ./classes.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf classes
mkdir -p classes
clojure -M:aot
