#!/bin/sh
# Build the project: fetch dependencies and AOT-compile the CLI so that start-up is fast.
set -eu
cd "$(dirname "$0")"
mkdir -p classes
clojure -P
clojure -M -e "(binding [*compile-path* \"classes\"] (compile 'sat.cli))"
