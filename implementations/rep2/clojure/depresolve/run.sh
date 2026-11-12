#!/bin/sh
# Runs depresolve: reads the input on stdin, writes the result to stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec java -XX:+UseSerialGC -cp "$(cat "$DIR/.classpath")" depresolve.cli "$@"
