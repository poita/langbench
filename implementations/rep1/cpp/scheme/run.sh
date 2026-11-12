#!/bin/sh
# Run the interpreter: Scheme program on stdin, output on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/scheme"
