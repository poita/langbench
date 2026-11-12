#!/bin/sh
# Runs the SAT solver: DIMACS CNF on stdin, answer on stdout. Run build.sh first.
ROOT=$(cd "$(dirname "$0")" && pwd)
exec java -XX:+UseSerialGC -XX:TieredStopAtLevel=4 -cp "$(cat "$ROOT/target/classpath")" sat.cli
