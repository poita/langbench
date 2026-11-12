#!/bin/sh
# Runs the CLI: Datalog program on stdin, answers on stdout.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/build/datalog"
