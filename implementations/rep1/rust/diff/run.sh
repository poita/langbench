#!/bin/sh
# Run the CLI: reads stdin, writes stdout. Works from any current directory.
exec "$(dirname "$0")/target/release/linediff" "$@"
