#!/bin/sh
# Runs the validator: JSON request on stdin, one valid/invalid line per test on stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M -m jsonschema.cli
