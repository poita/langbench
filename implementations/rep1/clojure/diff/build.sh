#!/bin/sh
# Builds the project: resolves dependencies and AOT-compiles the CLI into classes/.
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -P
clojure -M -e "(compile 'diff.main)"
