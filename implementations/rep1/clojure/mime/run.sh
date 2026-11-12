#!/bin/sh
# Runs the mime command-line tool: run.sh <input path> <output directory>
DIR="$(cd "$(dirname "$0")" && pwd)"
CP="$(tail -n 1 "$DIR/.classpath")"
# Make the relative source paths in the classpath absolute.
ABS=""
OLDIFS="$IFS"; IFS=:
for p in $CP; do
  case "$p" in
    /*) ;;
    *) p="$DIR/$p" ;;
  esac
  ABS="$ABS:$p"
done
IFS="$OLDIFS"
exec java -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xshare:auto -cp "$DIR/classes$ABS" mime.main "$@"
