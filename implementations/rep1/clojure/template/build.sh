#!/bin/sh
# Build the command-line tool: AOT-compile it into ./classes and record the
# runtime classpath so that run.sh can start a JVM without the clojure CLI.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
rm -rf classes
mkdir -p classes
clojure -M:aot
echo "$dir/classes:$dir/src:$(clojure -Spath | sed "s/^src://")" > .classpath
