#!/bin/sh
# Usage: run.sh <input directory> <output directory>
ROOT=$(cd "$(dirname "$0")" && pwd)
if [ -f "$ROOT/target/classpath" ]; then
  exec java -cp "$ROOT/target/classes:$(cat "$ROOT/target/classpath")" sqlitefile.cli "$@"
else
  cd "$ROOT" && exec clojure -M:run "$@"
fi
