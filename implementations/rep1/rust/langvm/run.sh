#!/bin/sh
# Run langvm: reads a module stream on stdin, writes the result to stdout.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/target/release/langvm" "$@"
