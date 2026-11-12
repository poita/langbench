#!/bin/sh
# Run the CLI: reads stdin, writes stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/bin/diff-cli" "$@"
