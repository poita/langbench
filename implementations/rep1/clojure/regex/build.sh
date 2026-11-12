#!/usr/bin/env bash
# Build the project: AOT-compile the command-line tool and record the classpath
# so that run.sh can start the JVM directly (no clojure CLI start-up cost).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
rm -rf classes
mkdir -p classes target
clojure -Spath > target/classpath
clojure -M -e "(binding [*compile-path* \"classes\"] (compile 'regex.cli))"
