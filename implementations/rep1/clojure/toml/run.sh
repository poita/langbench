#!/bin/sh
# Runs the command-line tool: reads stdin, writes stdout.
# Works from any current directory.
cd "$(dirname "$0")" || exit 1
exec clojure -Sdeps '{:paths ["src" "classes"]}' -M -m toml.cli
