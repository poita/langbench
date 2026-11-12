#!/usr/bin/env bash
# Build minisql: AOT-compile the CLI (and the library it needs) into
# target/classes so that run.sh starts quickly.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf target/classes
mkdir -p target/classes
clojure -M:aot -e '(binding [*compile-path* "target/classes"] (compile (quote minisql.cli)))'
