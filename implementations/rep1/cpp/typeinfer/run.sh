#!/bin/sh
# Runs the typeinfer CLI: program on stdin, report on stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/typeinfer" "$@"
