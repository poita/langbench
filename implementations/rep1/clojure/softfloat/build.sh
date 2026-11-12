#!/bin/sh
# Build: AOT-compile the CLI into ./classes and record the runtime classpath.
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -M -e "(binding [*compile-path* \"classes\"] (compile 'softfloat.cli))"
echo "classes:src:$(clojure -Spath)" > classes/classpath.txt
