#!/usr/bin/env bash
# Build the project: AOT-compile the CLI and cache the classpath.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf target
mkdir -p target/classes
clojure -M:compile
clojure -Spath > target/classpath
