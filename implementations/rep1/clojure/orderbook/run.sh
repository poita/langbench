#!/usr/bin/env bash
# Run the order book CLI: commands on stdin, events on stdout.
# Requires build.sh to have been run first.
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
exec java -cp "$(cat target/classpath)" orderbook.cli "$@"
