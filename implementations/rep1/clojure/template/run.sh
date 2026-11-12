#!/bin/sh
# Run the template engine: JSON context and templates on stdin, result on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec java -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto \
  -cp "$(cat "$dir/.classpath")" template.main
