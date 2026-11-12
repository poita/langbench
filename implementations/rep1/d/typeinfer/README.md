# typeinfer

Hindley-Milner type inference (Damas-Milner with let-polymorphism, Algorithm J)
for a small ML-like language, written in D. It is a library plus a thin
command-line tool: give it a program, get back the principal type of every
top-level declaration, or `error: unify|occurs|unbound` for each declaration
that does not type-check.

The language has integers, booleans, unit, tuples, lists, `fun`, `let`,
`let rec`, `if`, the usual arithmetic/comparison/boolean operators, `::`, and a
few built-ins (`not fst snd hd tl null length map fold`). There is no value
restriction: every `let` is generalised.

## Design

* **Types** are a shared graph (a DAG); variables are union-find nodes with a
  level. Every walk (occurs check, generalisation, instantiation) visits each
  distinct node once, so a type whose expansion is exponentially large is still
  handled in time linear in its DAG size.
* **Unification** is union-find unification with an occurs check at each
  binding; the same walk lowers variable levels. Unified constructor nodes are
  merged so repeated unification of the same shared structure is O(1).
* **Generalisation** is level-based (Rémy), so it never scans the environment;
  the environment is a hash map with an undo trail, so lookups do not depend on
  the number of bindings in scope.
* **Instantiation** copies quantified variables and shares sub-terms that contain none.

## Layout

| Module | Responsibility |
| --- | --- |
| `typeinfer.lexer` | text to tokens |
| `typeinfer.ast`, `typeinfer.parser` | syntax tree and recursive-descent parser |
| `typeinfer.types` | type graph, union-find `prune` |
| `typeinfer.solver` | unify, generalise, instantiate |
| `typeinfer.env`, `typeinfer.builtins` | scoped environment, initial bindings |
| `typeinfer.infer` | Algorithm J (`Inferencer`) |
| `typeinfer.printer` | rendering types (`'a`, `'b`, ... naming) |
| `typeinfer.program` | `checkSource` / `typeCheck` entry points |
| `app.d` | the CLI |

## Build

Requires LDC and dub.

```sh
./build.sh                       # same as: dub build -b release --compiler=ldc2
```

The binary is `bin/typeinfer`; `./run.sh` runs it from any directory.

## Command line

The program is read from stdin; one line per declaration goes to stdout. The exit
code is 0 even for type errors.

```sh
$ printf 'let id x = x;;\n(id 1, id true);;\nfun x -> x x;;\n' | ./run.sh
id : 'a -> 'a
- : int * bool
error: occurs
```

A bare expression prints as `- : type`. Syntax errors are not part of the
specified behaviour: output for the declarations before one is kept and a
message goes to stderr.

The CLI runs inference on a thread with a 1 GiB stack, because parsing and
inference recurse as deeply as the input nests.

## Library

Add it as a dub dependency (it provides a `library` configuration) and:

```d
import std.stdio;
import typeinfer;

void main()
{
    // Whole program to text.
    write(typeCheck("let compose f g x = f (g x);; compose;;"));

    // Structured results.
    auto report = checkSource("let k x y = x;; k 1;; undefined;;");
    foreach (d; report.decls)
        writeln(d.ok ? d.type : "failed", "  ", d.error);

    // Declaration by declaration, keeping the environment.
    auto inf = new Inferencer;
    auto parser = new Parser("let f x = x;; f 3;;");
    while (!parser.atEnd)
        writeln(inf.check(parser.parseDecl()));   // "f : 'a -> 'a", "- : int"
}
```

Very deeply nested programs (thousands of levels) need a large call stack; run
them on a `core.thread.Thread` with a big stack size, as `app.d` does.

## Tests

```sh
dub test --compiler=ldc2
```

The tests are D `unittest` blocks next to the code they cover, including the
worked examples from the specification, error-kind ordering, sharing of large
types, and deep nesting. For the end-to-end suite:
`python3 run_tests.py typeinfer -- typeinfer/run.sh` from the repository root.
