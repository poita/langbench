#!/bin/sh
# Build the project: resolve dependencies and AOT-compile the CLI.
set -e
cd "$(dirname "$0")"
mkdir -p target/classes
clojure -P
clojure -M:compile
