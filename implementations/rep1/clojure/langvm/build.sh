#!/bin/sh
# Build langvm: ahead-of-time compile the Clojure sources into classes/ and
# record the runtime classpath in .classpath (used by run.sh).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"

rm -rf classes
mkdir -p classes

# Resolve dependencies and write an absolute classpath.
clojure -Spath | tr ':' '\n' | while IFS= read -r entry; do
  case "$entry" in
    /*) printf '%s\n' "$entry" ;;
    *) printf '%s\n' "$dir/$entry" ;;
  esac
done | paste -sd: - > .classpath

# AOT-compile the command-line tool and, transitively, the whole library.
clojure -M -e "(compile 'langvm.cli)" 2>&1 | grep -v '^Picked up' || true
test -f classes/langvm/cli.class
