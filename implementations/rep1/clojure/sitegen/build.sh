#!/usr/bin/env bash
# Builds sitegen: AOT-compiles the command-line tool into ./classes and
# records the absolute runtime classpath in ./target/classpath, so that
# run.sh can start the JVM directly.  Works from any current directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

rm -rf classes target
mkdir -p classes target

# Compile sitegen.main and, transitively, every namespace it uses.
clojure -M:build

# Runtime classpath: the compiled classes plus the dependency jars (no
# sources), with absolute entries.
IFS=':' read -r -a entries <<< "$(clojure -Spath -A:classes)"
cp=""
for entry in "${entries[@]}"; do
  case "$entry" in
    src|/*/src) continue ;;
    /*) ;;
    *) entry="$here/$entry" ;;
  esac
  cp="${cp:+$cp:}$entry"
done
printf '%s\n' "$cp" > target/classpath
