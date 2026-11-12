#!/bin/sh
# Usage: run.sh <input directory> <output directory>
DIR="$(cd "$(dirname "$0")" && pwd)"
exec java -cp "$DIR/classes:$(cat "$DIR/.classpath")" buildsys.main "$@"
