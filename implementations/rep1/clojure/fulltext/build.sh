#!/bin/sh
# Build fulltext: AOT-compile the CLI and record an absolute classpath.
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"
mkdir -p classes target
clojure -J-Dclojure.compile.path=classes -M -e "(compile 'fulltext.main)"
# Absolute classpath (classes first), so run.sh works from any directory.
clojure -Spath | tr ':' '\n' | while IFS= read -r entry; do
  case "$entry" in
    /*) printf '%s\n' "$entry" ;;
    *) printf '%s\n' "$ROOT/$entry" ;;
  esac
done | grep -vx "$ROOT/src" | { printf '%s\n' "$ROOT/classes"; cat; } | paste -sd: - > target/classpath.txt
