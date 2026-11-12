#!/usr/bin/env bash
# Run the regex CLI: reads the test input on stdin, writes results to stdout.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
exec java -cp "classes:$(cat target/classpath)" clojure.main -m regex.cli
