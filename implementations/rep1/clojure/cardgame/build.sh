#!/bin/sh
# Build cardgame: resolve dependencies, AOT-compile the CLI into target/classes
# and record the runtime classpath in target/classpath.  Works from any
# current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p target/classes
rm -rf target/classes/*
# The project's own paths are made absolute so that run.sh can be started
# from any directory.
clojure -Sdeps "{:paths [\"$dir/target/classes\" \"$dir/src\"]}" -Spath > target/classpath
clojure -Sdeps "{:paths [\"$dir/target/classes\" \"$dir/src\"]}" \
        -J-Dclojure.compile.path="$dir/target/classes" \
        -M -e "(compile 'cardgame.cli)"
