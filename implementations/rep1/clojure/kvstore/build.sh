#!/bin/sh
# Compile the project ahead of time and record the runtime classpath.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
mkdir -p classes target
clojure -M -e "(binding [*compile-path* \"classes\"] (compile 'kvstore.cli))"
# absolute classpath so run.sh works from any directory
clojure -Spath | tr ':' '\n' | while IFS= read -r entry; do
  case "$entry" in
    /*) printf '%s\n' "$entry" ;;
    *) printf '%s\n' "$DIR/$entry" ;;
  esac
done | paste -sd: - > target/classpath
