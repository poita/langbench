#!/bin/sh
# Runs the CLI: match file on stdin, log on stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/spiremark"
