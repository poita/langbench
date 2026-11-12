#!/bin/sh
# Run the depresolve CLI (stdin -> stdout); works from any directory.
exec "$(dirname "$0")/target/release/depresolve" "$@"
