# datalog — Datalog engine with stratified negation

Read a Datalog program from stdin, compute its (unique) stratified model, and
answer every query in the program. If the program is not safe or not
stratifiable, print exactly `error` instead. The exit code is 0 in both cases;
stderr is ignored.

## Input

The whole of stdin is one program: a sequence of clauses. Each clause is a
**fact**, a **rule** or a **query** and ends with `.`. Whitespace (space, tab,
CR, LF) may appear between any two tokens; clauses may span lines and several
clauses may share a line. A `%` starts a comment that runs to the end of the
line (there are no string literals, so a `%` can never be part of a token).
Input is ASCII; it may be empty or consist only of whitespace and comments.
A program without queries produces no output at all, unless it is unsafe or
unstratifiable, in which case `error` is printed as for any other program.

### Tokens

| token          | syntax                                                     |
|----------------|------------------------------------------------------------|
| identifier     | `[a-z][a-z0-9_]*` — used for predicate names and constants |
| variable       | `[A-Z][A-Za-z0-9_]*`                                       |
| anonymous var  | `_` (a single underscore on its own)                        |
| integer        | `-?[0-9]+`, canonical: no leading zeros except `0` itself, never `-0`; magnitude ≤ 1,000,000,000 |
| keyword        | `not` — reserved; never a predicate name or constant (but `nothing`, `not_x` are ordinary identifiers) |
| punctuation    | `(`  `)`  `,`  `.`  `:-`  `?-`  `<`  `<=`  `>`  `>=`  `=`  `!=` |

A `-` only ever occurs as the first character of a negative integer or inside
`:-` / `?-`; tokenisation is longest-match (`<=` is one token, `X<-1` lexes as
`X`, `<`, `-1`). A negative integer is always preceded by `(`, `,`, a
comparison operator or whitespace, never by a letter or digit. In the tests every `:-` and `?-`
is followed by at least one whitespace character or a letter, `not` is always
followed by whitespace, and no token starts with `_` other than `_` itself.
Programs in the tests are always syntactically well-formed; behaviour on
malformed input is unspecified.

### Grammar

```
program    = clause*
clause     = fact | rule | query
fact       = atom "."
rule       = atom ":-" literal ( "," literal )* "."
query      = "?-" atom "."
atom       = identifier "(" term ( "," term )* ")"
literal    = atom | "not" atom | term cmpop term
cmpop      = "<" | "<=" | ">" | ">=" | "=" | "!="
term       = constant | variable | "_"
constant   = integer | identifier
```

- A **constant** is either an integer or an identifier. `5` and `five` are
  different constants. Predicate names and constants live in separate
  namespaces: `edge(edge, path).` is fine.
- Every predicate has at least one argument. A predicate is identified by
  its name and its arity together: `r(X)` and `r(X, Y)` refer to two
  different predicates, `r/1` and `r/2`. When one name is used with more
  than one arity, at most one of those arities has facts or rules; the
  name at any other arity is a predicate with no facts and no rules, which
  is empty (see below).
- A **fact** is a rule with an empty body. A fact whose head contains a
  variable or `_` is *unsafe* (see below) and therefore an `error`.
- Each occurrence of `_` is a distinct fresh variable that appears nowhere
  else. It is allowed in positive body atoms and in queries.
- A program may reference a predicate (in a body, negated or not, or in a
  query) that has no facts and no rules; such a predicate is simply empty.
- The same predicate may have both facts and rules, and duplicate facts or
  rules are harmless (relations are sets).
- Variable names are scoped to a single clause.

## Ordering of constants

A single total order on constants is used both by the comparison built-ins
and for sorting output:

1. every integer is less than every identifier;
2. integers compare numerically;
3. identifiers compare lexicographically by ASCII byte value, a proper prefix
   sorting first (plain `strcmp` order): `a` < `a0` < `a_` < `a_b` < `aa` < `ab` < `b`.

Tuples of constants compare lexicographically, position by position.

## Safety (checked first)

A rule is **safe** when every variable that occurs in its head, in a negated
atom, or in a comparison also occurs in at least one **positive** (non-negated)
body atom of the same rule. Since every `_` is a fresh variable, a `_` in a
head, in a negated atom, or in a comparison always makes the rule unsafe. A
rule with no body (a fact) is safe only if its head contains no variables.

Comparisons never bind variables: `p(Y) :- q(X), X = Y.` and
`p(X) :- q(X), Y = 5.` are both unsafe, because `Y` occurs in no positive
body atom. Only positive body atoms make a variable safe.

If any rule is unsafe, print `error`.

## Stratification (checked second)

Build the predicate dependency graph: for every rule with head predicate `p`
and every body atom (positive or negated) with predicate `q`, add an edge
`q → p`, marked **negative** if the atom is negated. Comparisons add no edges.
The program is **stratifiable** iff no cycle of this graph contains a negative
edge. If it is not stratifiable, print `error`.

Equivalently, a stratification assigns each predicate an integer stratum such
that for every rule, `stratum(head) ≥ stratum(q)` for every positive body atom
`q` and `stratum(head) > stratum(q)` for every negated body atom `q`; the
program is stratifiable iff such an assignment exists.

Both checks apply to the whole program before any query is answered, and
`error` (followed by `\n`) is then the **only** output, whatever else the
program contains.

## Semantics

The result is the standard perfect model of the stratified program.
Operationally: process strata from lowest to highest; within a stratum,
repeatedly apply every rule whose head is in that stratum until no new tuple
appears (least fixpoint). Applying a rule means: for every assignment of
constants to the rule's variables such that

- each positive body atom `q(t1, …, tn)` is a tuple currently in `q`,
- each negated body atom `not q(t1, …, tn)` is **not** a tuple in `q`
  (`q` is in a strictly lower stratum, so it is already complete),
- each comparison holds under the ordering above (`=` is equality of
  constants; an integer never equals an identifier; `!=` is its negation;
  `<`, `<=`, `>`, `>=` use the total order, so `5 < abc` is true and
  `b < a` is false),

the head, with variables substituted, is added to the head predicate. A
variable that occurs several times in a body atom, or across atoms, must be
bound to the same constant at every occurrence (`loop(X) :- edge(X, X).`
selects self-loops). The order of literals in a body carries no meaning:
`p(X) :- not q(X), r(X).` and `p(X) :- r(X), not q(X).` are the same rule.
The model does not depend on which valid stratification is chosen. Rules may
be non-linear: a body may contain several atoms of predicates that are
recursive with the head (`link(X, Z) :- link(X, Y), link(Y, Z).`, or two
mutually recursive predicates joined in one body), and an incremental
evaluation must then combine tuples derived in earlier rounds with tuples
derived later in *every* such position, not just the first.

## Queries

The whole program is read first; the model is computed once; then the
queries are answered **in the order they appear in the input**, regardless of
where facts and rules appear relative to them.

A query `?- p(t1, …, tn).` matches every tuple of `p` such that every
constant `ti` equals the tuple's i-th component and every variable that
occurs several times in the query is matched to the same constant at each
of its positions (`_` and variables occurring once match anything). For
each query print

1. the matching tuples, one per line, in ascending tuple order (see
   *Ordering of constants*), each formatted as `p(v1, v2, …, vn)`: the
   predicate name, `(`, the constants joined by a comma and a single space,
   `)`. Integers are printed in canonical decimal (`-5`, `0`, `12`).
   The full tuple is printed, not the query pattern.
2. a line `-- N` where `N` is the number of tuples printed (`-- 0` when
   nothing matched, including queries on predicates that do not exist).

Every line ends with `\n`. Nothing else is printed.

## Worked examples

### Example 1 — transitive closure

Input:
```
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
?- path(X, X).
```
Output:
```
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
```

### Example 2 — negation, comparisons, mixed constants

Input:
```
% nodes and links
node(a). node(b). node(c). node(5). node(-2).
link(a, b). link(b, 5). link(5, 5).
reach(X, Y) :- link(X, Y).
reach(X, Z) :- reach(X, Y), link(Y, Z).
sink(X) :- node(X), not hasout(X).
hasout(X) :- link(X, _).
small(X) :- node(X), X < a.
?- sink(X).
?- small(X).
?- reach(a, X).
?- reach(X, X).
```
Output:
```
sink(-2)
sink(c)
-- 2
small(-2)
small(5)
-- 2
reach(a, 5)
reach(a, b)
-- 2
reach(5, 5)
-- 1
```
`hasout` must be complete before `sink` is evaluated, so `sink` lies in a
higher stratum. `-2` and `c` have no outgoing link. Integers sort before
identifiers, hence `reach(a, 5)` precedes `reach(a, b)`; `5 < a` and
`-2 < a` hold because every integer is less than every identifier, while
`b < a` and `c < a` are false.

### Example 3 — errors

Input:
```
edge(1, 2).
win(X) :- edge(X, Y), not win(Y).
?- win(X).
```
Output:
```
error
```
(`win` depends negatively on itself: the cycle `win → win` contains a
negative edge, so the program is not stratifiable.)

Input:
```
q(1).
?- q(X).
p(X) :- q(Y).
?- p(X).
```
Output:
```
error
```
(`X` in the head of the second rule does not occur in a positive body atom,
so the rule is unsafe; the earlier query produces no output.)

## Sizes and performance

- At most 50,000 clauses; predicates have at most 6 arguments; at most 60
  distinct predicates; a rule body has at most 8 literals.
- The largest tests are: the transitive closure of a 2000-node chain
  (about 2,000,000 derived tuples, though only a few thousand lines of
  output); the transitive closure of a random graph with 500 nodes and 3000
  edges together with several strata of negation over it; same-generation on
  a 2000-node tree; an even/odd mutual recursion over a 2000-element chain;
  a 500-person all-pairs comparison join (~125,000 tuples).
- No single query prints more than 5,000 lines and the total output of a
  test is under 200 KB.
- A semi-naive evaluation with hash-indexed relations completes every test
  in a few seconds at most in a compiled language (about 10 s for the chain
  test in the Python reference); a naive fixpoint that re-derives everything
  each round is far too slow for the chain test. Suggested per-test timeout:
  30 seconds.
