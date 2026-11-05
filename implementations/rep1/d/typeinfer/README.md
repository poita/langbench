# typeinfer

Hindley-Milner type inference for a small ML-like language, as a D library
plus a command-line tool. It reads a program (a sequence of `;;`-terminated
declarations) and prints the principal type of every top-level declaration,
or `error: unify` / `error: occurs` / `error: unbound` for the ones that
don't type-check.

The engine is Algorithm J: a single left-to-right recursive pass with
destructive union-find unification, a fused occurs check and level
adjustment, level-based (Rémy-style) in-place generalisation, and
instantiation by a memoised copy of the type DAG that shares unchanged
sub-terms. The environment is a per-name binding stack indexed by interned
name id, so generalisation and lookup never depend on the environment size.
Only the D standard library is used.

## Building

Requires LDC (tested with 1.41.0) and dub (1.40.0).

```
./build.sh                                  # or: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                    # unit tests
```

## Command-line use

`typeinfer` (or `./run.sh`) reads the whole program on stdin and writes one
line per declaration to stdout:

```
$ printf 'let id = fun x -> x;;\nlet compose f g x = f (g x);;\n(id 1, id true);;\nfun x -> x x;;\n' | ./run.sh
id : 'a -> 'a
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
- : int * bool
error: occurs
```

* `name : type` for a `let` / `let rec` declaration, `- : type` for a bare
  expression.
* A failing declaration adds nothing to the environment; processing continues.
* Exit code 0 (type errors are normal results). Malformed input (outside the specification) prints a
  message on stderr and exits with code 1.

The language and the exact output format are described in
`problems/typeinfer/SPEC.md` of the surrounding repository: integer, boolean
and unit literals, lists, tuples, `fun`, `if`, `let` / `let rec` (all
generalised, no value restriction), arithmetic/comparison/boolean operators,
and the built-ins `not fst snd hd tl null length map fold`.

## Library

Add the package as a dependency (`dependency "typeinfer" path="..."`, using the
`library` configuration) and `import typeinfer;`.

| Module | Responsibility |
| --- | --- |
| `typeinfer.lexer` | one-pass tokeniser, identifier interning |
| `typeinfer.ast`, `typeinfer.parser` | flat AST, recursive-descent parser |
| `typeinfer.types` | type-node arena (`TypeStore`) with union-find `find` |
| `typeinfer.unify` | unification with fused occurs check / level adjustment |
| `typeinfer.scheme` | in-place generalisation and memoised instantiation |
| `typeinfer.infer` | the `Inferencer` (Algorithm J, environment stacks) |
| `typeinfer.printer` | rendering types in the specified syntax |
| `typeinfer.checker` | `TypeChecker` and `inferProgram` facade |
| `typeinfer.stack` | `runWithLargeStack` for deeply nested programs |
| `typeinfer.errors` | `ErrorKind`, `TypeError`, `SyntaxError` |

Example:

```d
import std.stdio;
import typeinfer;

void main()
{
    // One call: source text in, the CLI's output text out.
    write(inferProgram("let twice f x = f (f x);;"));
    // twice : ('a -> 'a) -> 'a -> 'a

    // Incremental use: structured results, environment kept between calls.
    auto checker = new TypeChecker;
    foreach (r; checker.check("let k x y = x;; k 1;; k + 1;;"))
        writeln(r.ok ? r.type : toText(r.error));
    // 'a -> 'b -> 'a
    // 'a -> int      (this is the type of  k 1)
    // unify
}
```

Inference recurses once per level of expression nesting, which the
specification allows to reach thousands. The CLI therefore runs on a thread
with a 1 GiB stack; library users handling untrusted or very deep input
should do the same with `runWithLargeStack({ ... })`.

## Layout

```
dub.sdl          manifest (configurations: application, library, unittest)
source/typeinfer library modules
app/main.d       the command-line tool
tests/           unit tests (compiled only into the unittest configuration)
build.sh run.sh  build / run scripts
```
