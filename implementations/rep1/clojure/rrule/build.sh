#!/bin/sh
# Build the project: AOT-compile the CLI into target/classes and record the
# runtime classpath so that run.sh starts without resolving dependencies.
set -e
cd "$(dirname "$0")"
rm -rf target
mkdir -p target/classes
deps="{:paths [\"$PWD/src\" \"$PWD/target/classes\"]}"
clojure -Sdeps "$deps" -M -e "(binding [*compile-path* \"target/classes\"] (compile 'rrule.cli))"
clojure -Sdeps "$deps" -Spath > target/classpath
