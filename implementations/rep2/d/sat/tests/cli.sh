#!/bin/sh
# Smoke tests for the command-line tool (run after build.sh).
set -e
run="$(dirname "$0")/../run.sh"
check() { # name expected input
    got=$(printf '%s' "$3" | "$run")
    [ "$got" = "$2" ] || { echo "FAIL $1: got '$got'"; exit 1; }
}
check empty    "SAT
0" "p cnf 0 0"
check unsat    "UNSAT" "p cnf 2 4
1 2
0 -1 2 0
-1 -2 0 1 -2 0"
check emptycl  "UNSAT" "p cnf 3 2
1 2 0
0"
check unit     "SAT
1 -2 0" "c comment
p cnf 2 2
1 0
-2 0"
echo "cli tests passed"
