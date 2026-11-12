#!/usr/bin/env bash
# Build the order book project: AOT-compile the CLI and record the runtime
# classpath so that run.sh can start the JVM directly.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf target
mkdir -p target/classes

# Runtime classpath (src + target/classes + Clojure jars).
clojure -Spath -A:aot > target/classpath

# AOT-compile the CLI namespace and everything it requires.
clojure -M:aot -e "(do (binding [*compile-path* \"target/classes\"] (compile 'orderbook.cli)) nil)"
