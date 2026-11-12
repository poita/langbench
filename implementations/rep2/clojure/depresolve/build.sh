#!/bin/sh
# Builds depresolve: AOT-compiles the CLI into classes/ and records the
# classpath in .classpath so that run.sh can start a JVM directly.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
mkdir -p classes
clojure -M -e "(binding [*compile-path* \"classes\"] (compile 'depresolve.cli))"
# Absolute classpath: compiled classes first, then sources and libraries.
clojure -Spath | sed "s#^#$DIR/classes:#; s#\(^\|:\)src\(:\|\$\)#\1$DIR/src\2#" > .classpath
