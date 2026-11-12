#!/bin/sh
# Builds the project: resolves the classpath and AOT-compiles the CLI into
# target/classes so that run.sh starts quickly.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
rm -rf target
mkdir -p target/classes
clojure -Sdeps '{:paths ["src" "target/classes"]}' -J-Dclojure.compile.path=target/classes \
  -M -e "(compile 'jq.cli)"
CP=$(clojure -Spath)
printf '%s' "$DIR/target/classes:$CP" > target/classpath
