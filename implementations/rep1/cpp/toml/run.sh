#!/bin/sh
# Runs the CLI: stdin is "<mode>\n<document>", stdout is the result.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/toml-tool"
