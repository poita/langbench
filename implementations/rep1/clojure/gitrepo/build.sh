#!/bin/sh
# Build gitrepo: AOT-compile the command-line tool into target/classes.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
rm -rf target/classes
mkdir -p target/classes
clojure -M:aot
