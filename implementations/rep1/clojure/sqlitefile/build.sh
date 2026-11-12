#!/bin/sh
# Build the project: AOT-compile the command-line tool and record the classpath.
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"
mkdir -p target/classes
clojure -M:build -e "(compile 'sqlitefile.cli)"
# Absolute classpath so run.sh works from any directory.
clojure -Spath | tr ':' '\n' | while IFS= read -r entry; do
  case "$entry" in
    /*) printf '%s\n' "$entry" ;;
    *) printf '%s\n' "$ROOT/$entry" ;;
  esac
done | paste -sd: - > target/classpath
