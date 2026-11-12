#!/bin/sh
# Builds the project: AOT-compiles the CLI and records the runtime classpath.
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"
rm -rf target
mkdir -p target/classes
clojure -M:aot
CP=$(clojure -Sdeps '{:paths []}' -Spath)
echo "$ROOT/target/classes:$CP" > target/classpath
