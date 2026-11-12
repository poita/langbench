#!/usr/bin/env bash
# Build: resolve dependencies and AOT-compile the CLI into target/classes so
# that run.sh starts quickly.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf target/classes
mkdir -p target/classes
clojure -P
clojure -J-Dclojure.compile.path=target/classes -M -e "(compile 'datalog.main)"
