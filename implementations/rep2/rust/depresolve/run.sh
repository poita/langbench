#!/bin/sh
# Run the resolver: reads the registry + root manifest on stdin, writes the
# resolution to stdout. Works from any directory.
exec "$(dirname "$0")/target/release/depresolve" "$@"
