#!/bin/sh
# Builds the project: AOT-compiles the CLI into target/classes and records the
# resolved classpath in target/classpath for run.sh.
set -e
cd "$(dirname "$0")"
mkdir -p target/classes
rm -rf target/classes/*
clojure -J-Dclojure.compile.path=target/classes -M -e "(compile 'bigint.cli)"
clojure -Spath > target/classpath.tmp
# make relative entries absolute so run.sh works from anywhere
tr ':' '\n' < target/classpath.tmp | sed "s|^src\$|$PWD/src|" | paste -sd: - > target/classpath
rm target/classpath.tmp
echo "$PWD/target/classes:$(cat target/classpath)" > target/classpath
