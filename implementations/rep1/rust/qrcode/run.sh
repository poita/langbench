#!/bin/sh
# Run the CLI: reads queries on stdin, writes symbols to stdout.
exec "$(dirname "$0")/target/release/qrcode" "$@"
