#!/bin/sh
# Run the Datalog engine: program on stdin, answers on stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/bin/datalog" "$@"
