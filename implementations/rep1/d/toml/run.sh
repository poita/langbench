#!/bin/sh
# Run the toml tool: reads "decode\n<toml>" or "encode\n<json>" on stdin.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/bin/toml-cli" "$@"
