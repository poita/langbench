#!/bin/sh
# Run the CLI: reads queries on stdin, writes symbols to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/qrcode-cli" "$@"
