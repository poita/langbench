#!/bin/sh
# Builds the project: resolves dependencies and AOT-compiles the CLI so that
# run.sh starts quickly. Works from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
rm -rf target/classes
mkdir -p target/classes
clojure -P -M:run
clojure -M -e "(binding [*compile-path* \"target/classes\"] (compile 'qrcode.cli))"
