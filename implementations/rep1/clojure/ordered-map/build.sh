#!/bin/sh
# Builds the project: AOT-compiles the CLI (with direct linking) into target/classes.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
rm -rf target/classes
mkdir -p target/classes
clojure -J-Dclojure.compiler.direct-linking=true -J-Dclojure.compile.path=target/classes \
  -M -e "(binding [*compile-path* \"target/classes\"] (compile 'ordered-map.main))"
# Resolve the classpath once so run.sh can start the JVM directly.
clojure -Spath > target/classpath.txt
