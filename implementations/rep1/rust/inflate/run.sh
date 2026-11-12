#!/bin/sh
# Run the CLI: hex on stdin, hex (or `error`) on stdout.
exec "$(dirname "$0")/target/release/inflate" "$@"
