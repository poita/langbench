#!/usr/bin/env bash
# Build the project: resolve dependencies, AOT-compile the CLI and record the
# runtime classpath that run.sh uses.  Works from any current directory.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
mkdir -p target/classes
rm -rf target/classes/*
# Absolute classpath (the "src" entry of :paths is relative to the project).
CP="$(clojure -Spath | sed -e "s#^src:#$ROOT/src:#" -e "s#:src:#:$ROOT/src:#")"
clojure -M -e "(binding [*compile-path* \"target/classes\"] (compile 'buildsys.main))" >&2
printf '%s\n' "$ROOT/target/classes:$CP" > target/classpath
