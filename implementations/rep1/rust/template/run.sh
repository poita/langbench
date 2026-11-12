#!/bin/sh
# Run the template engine: reads stdin, writes stdout.
exec "$(dirname "$0")/target/release/template" "$@"
