#!/bin/sh
# Builds buildsys: resolves the classpath and AOT-compiles the program into
# classes/, so that run.sh can start the JVM directly.
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -Spath > .classpath.tmp
CP="classes:$(cat .classpath.tmp)"
rm -rf classes/*
java -cp "$CP" -Dclojure.compile.path=classes clojure.main -e "(compile 'buildsys.main)"
mv .classpath.tmp .classpath
