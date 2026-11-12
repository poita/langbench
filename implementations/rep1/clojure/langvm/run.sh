#!/bin/sh
# Run langvm: read a Vellum module stream on stdin, write the program's output
# (or one diagnostic line) on stdout.  Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
[ -f "$dir/.classpath" ] || "$dir/build.sh" >&2
exec java -XX:-DontCompileHugeMethods -XX:+UseSerialGC -Xshare:auto \
  -cp "$(cat "$dir/.classpath")" langvm.cli
