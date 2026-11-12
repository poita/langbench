#!/bin/sh
# Run the CLI: filter on the first stdin line, JSON document after it.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/target/release/jqlite" "$@"
