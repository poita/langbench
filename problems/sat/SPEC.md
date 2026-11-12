# sat — CDCL SAT solver on DIMACS CNF

Decide whether a propositional formula in conjunctive normal form is
satisfiable, and if it is, print a satisfying assignment. The test suite
contains instances (random 3-SAT at the phase transition with up to 200
variables, pigeonhole formulas up to PHP(8)) that need a conflict-driven
clause-learning solver (two watched literals, first-UIP clause learning,
VSIDS-style branching, restarts), the intended solution.

## Input

Standard input is a text file in the DIMACS CNF format. It contains only
printable ASCII characters, spaces, tabs and `\n` line breaks (no `\r`, no
byte-order mark). Every line may have leading and trailing blanks (spaces or
tabs). Lines are classified by their first non-blank character:

- **Blank lines** (empty or blanks only) may appear anywhere and are ignored.
- **Comment lines**: the first non-blank character is `c`. The rest of the
  line is arbitrary and is ignored; `c` may be the whole line, or be followed
  directly by text with no space (`cfoo`). Comments may appear anywhere:
  before the header, between the numbers of a single clause, and after the
  last clause.
- **The header**: exactly one line `p cnf V C`, appearing before any clause
  data. `V >= 0` is the number of variables and `C >= 0` the number of
  clauses. The four tokens are separated by one or more blanks.
- **Clause data**: every other line after the header holds integers
  separated by one or more blanks. Taken together, these integers form a
  sequence in which a clause is a maximal run of non-zero integers terminated
  by a `0`. A clause may span several lines, and one line may contain several
  clauses. Exactly `C` clauses appear, and every clause, including the last,
  is terminated by `0`; the sequence never ends mid-clause.

Integers are written in decimal with an optional leading `-`, no `+` sign and
no leading zeros (`0` itself is the single digit `0`). A literal `k` with
`1 <= k <= V` means "variable k is true"; `-k` means "variable k is false". No
literal refers to a variable outside `1..V`.

A clause may be **empty** (a bare `0`), may contain **repeated literals**
(`1 1 -2 0`), and may contain **both a variable and its negation**
(`1 -1 0`, a tautology that is always satisfied; treat it as satisfied, do
not strip the pair). An empty clause makes the formula unsatisfiable. Some
variables in `1..V` may not occur in any clause. There are no `%` end markers
or other non-DIMACS decorations. The last line may or may not end with `\n`.

Inputs are well formed as described; no error handling is required and no
test exercises malformed input.

Limits across the test suite: `V <= 2000`, `C <= 6000`, at most 1000
literals in one clause, at most 18000 literal occurrences in total, and every
input is under 128 KB.

## Output

Write exactly one of the following to standard output.

If the formula is satisfiable:

```
SAT
<l1> <l2> ... <lV> 0
```

where line 2 lists one literal for **every** variable `1..V` in increasing
order of variable number — `li` is the decimal integer `i` if variable `i` is
assigned true and `-i` if it is assigned false (no `+` sign, no leading
zeros) — followed by a final `0`. The `V + 1` tokens are separated by single
spaces, there is no leading space, and the line ends with `\n`. For `V = 0`
the second line is just `0`. Variables that do not occur in any clause may be
given either value. Any assignment that satisfies every clause is accepted;
there is no canonical model.

If the formula is unsatisfiable:

```
UNSAT
```

Both words are upper case. Nothing else may be printed on stdout (no `s`/`v`
prefixes, no comments, no statistics). Exit with status 0 in both cases.

A formula with no clauses (`C = 0`) is satisfiable. A formula containing an
empty clause is unsatisfiable regardless of its other clauses.

## Examples

Input:

```
c three variables, two clauses
p cnf 3 2
1 -2 0
2 3 0
```

The reference solver prints the following; `1 -2 3 0` and `1 2 -3 0` are
among the other accepted answers:

```
SAT
-1 -2 3 0
```

Input (clauses split across lines and packed onto one line):

```
p cnf 2 4
1 2
0 -1 2 0
-1 -2 0 1 -2 0
```

Output:

```
UNSAT
```

Input:

```
p cnf 0 0
```

Output:

```
SAT
0
```

## Checking

Output is checked by `verify.py`, not by exact comparison. It rejects any
output whose first line is not exactly `SAT` or `UNSAT`; any `SAT` answer
whose second line is not exactly the tokens `1`/`-1`, `2`/`-2`, ..., `V`/`-V`
followed by `0`, separated by single spaces; any assignment that falsifies
some clause; and any `UNSAT` answer on an instance the reference solver (and
an independent solver) proved satisfiable. Trailing whitespace on a line and
trailing blank lines are tolerated; any other extra line is rejected.

## Input sizes

Largest tests: random 3-SAT with 200 variables and 852 clauses (both SAT and
UNSAT instances, at clause/variable ratio 4.26), PHP(8) pigeonhole (72
variables, 297 clauses, UNSAT), a 2000-variable / 6000-clause easy random
instance, graph-colouring encodings with up to 320 variables, and a single
1000-literal clause.
