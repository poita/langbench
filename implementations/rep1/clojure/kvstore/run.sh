#!/bin/sh
# Usage: run.sh <input dir> <output dir>
DIR=$(cd "$(dirname "$0")" && pwd)
exec java -Xss16m -XX:+UseSerialGC -cp "$DIR/classes:$(cat "$DIR/target/classpath")" kvstore.cli "$@"
