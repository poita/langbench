#!/usr/bin/env bash
# Usage: run.sh <input directory> <output directory>
# Runs the compiled sitegen tool; build it first with build.sh.
# Works from any current directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
java_bin="java"
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  java_bin="$JAVA_HOME/bin/java"
fi

if [ ! -f "$here/target/classpath" ]; then
  echo "sitegen: not built; run $here/build.sh first" >&2
  exit 1
fi

exec "$java_bin" -XX:+UseSerialGC -Xshare:auto \
  -cp "$(cat "$here/target/classpath")" sitegen.main "$@"
