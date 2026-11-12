#!/bin/sh
# Builds the project: AOT-compiles the command-line tool into classes/ and
# records the classpath in .classpath for run.sh.
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -Spath > .classpath
CP="$(tail -n 1 .classpath)"
java -Dclojure.compile.path=classes -cp "classes:$CP" clojure.main -e "(compile 'mime.main)"
