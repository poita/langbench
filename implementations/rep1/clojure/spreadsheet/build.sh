#!/bin/sh
# Builds the project: resolves dependencies, caches the classpath and
# AOT-compiles the program into classes/.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
rm -rf classes
mkdir -p classes
clojure -Spath | sed "s|^src:|$dir/src:|" > .classpath
clojure -M -e "(compile 'spreadsheet.main)"
