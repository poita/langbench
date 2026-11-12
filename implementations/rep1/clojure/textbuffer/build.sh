#!/bin/sh
# Resolves dependencies and AOT-compiles the CLI into target/classes.
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir" || exit 1
rm -rf target/classes
mkdir -p target/classes
exec clojure -J-Dclojure.compile.path=target/classes -M -e "(compile 'textbuffer.cli)"
