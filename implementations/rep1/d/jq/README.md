# jq (D)

A from-scratch interpreter for a subset of the [`jq`](https://jqlang.github.io/jq/)
filter language, written in D. It is split into a reusable library (`jq`) and a
thin command-line tool on top of it. The JSON parser, the serialiser and the
filter interpreter are all hand-written; only the D standard library and
druntime are used.

The semantics follow jq 1.7 (`jq -c`) for the supported subset: paths and
slices, `?`/try, generators and their exact evaluation order, arithmetic,
comparisons with jq's total order, `if`, `reduce`, `as` bindings, object and
array construction, and the builtins `empty error not length keys has type add
select map sort sort_by group_by unique reverse min max tostring tonumber`.
See `problems/jq/SPEC.md` in the parent repository for the full specification.

## Design

* **Values** (`jq.value`): a 16-byte tagged struct. `null`, booleans and
  numbers (doubles) are inline; strings, arrays and objects are references to
  immutable heap data, so copying/binding/indexing never copies contents.
* **Objects** are insertion-ordered key/value vectors with a lazy hash index
  for objects of more than 16 keys and a memoised sorted-key permutation used by
  comparison and `keys`. Parsed documents intern object keys.
* **Evaluation** (`jq.interp`) is a push-style tree walker:
  `eval(node, input, env, sink)` calls `sink` once per output. Sinks are
  non-escaping (stack) delegates. Nodes that always yield exactly one output
  take an allocation-free fast path (`evalOne`). Errors travel as a status
  (`false` + the pending error), so `?` never needs exceptions, and `try`
  distinguishes errors raised inside its term from downstream ones.
* **Sorting** sorts an index permutation (original index as tie-break, so it is stable) and evaluates `sort_by` /
  `group_by` keys exactly once per element.

## Layout

```
dub.sdl             project manifest (configurations: cli, library, unittest)
source/app.d        command-line tool
source/jq/          the library
  package.d         `import jq;` re-exports everything
  value.d           Value, JStr/JArr/JObj, ordering and equality
  json.d            JSON parser, serialiser, number formatting
  lexer.d parser.d ast.d    filter front end
  ops.d             arithmetic, indexing, slicing, data builtins
  interp.d          the evaluator
  program.d         Program: compile once, run many times
tests/              unit tests (separate from the library sources)
build.sh run.sh     build / run helpers
```

## Build

Requires LDC and dub.

```sh
./build.sh          # == dub build -b release --compiler=ldc2 --config=cli
dub test --compiler=ldc2
```

The executable is written to `bin/jq`.

## Command line

`run.sh` (or `bin/jq`) reads **all of stdin**: the first line is the filter, the
rest is exactly one JSON document. Every result is printed as compact JSON, one
per line. If evaluation hits an uncaught error, the results produced so far are
printed, followed by a line `error`. The exit code is always 0.

```console
$ printf '%s\n%s' '.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bob","age":25},{"name":"cy","age":30}]}' | ./run.sh
["cy","ann"]

$ printf '%s\n%s' '[(1,2) + (10,20)], (.[] | .a.b?)' '[{"a":{"b":1}},{"a":5},3]' | ./run.sh
[11,12,21,22]
1
error
```

## Library

Add the project as a dub dependency (`dependency "jq" path="../jq"`, using the
`library` configuration), then:

```d
import std.stdio : writeln;
import jq;

void main()
{
    // Compile once ...
    auto program = Program.compile(`.users | map({name, age}) | sort_by(.age)`);

    // ... run on any number of documents.
    auto doc = parseJson(`{"users":[{"name":"ann","age":31,"x":1},{"name":"bob","age":25}]}`);

    RunStatus status = program.run(doc, (Value v) {
        writeln(toJson(v));          // [{"name":"bob","age":25},{"name":"ann","age":31}]
    });
    assert(status.ok);

    // Or collect the results:
    Value[] results = program.runAll(doc, status);
}
```

* `parseJson(string)` -> `Value` (throws `JsonException` on malformed input).
* `Program.compile(string)` (throws `FilterException` on a malformed filter),
  `Program.run(input, emit)` and `Program.runAll(input, status)`.
* `toJson(Value)` / `writeValue(ref Buffer, Value)` serialise compactly.
* `compare` / `equals` implement jq's total order; `jq.ops` exposes the
  individual operations (`opAdd`, `indexValue`, `opSort`, ...). Operations
  report failure by returning an error value (`Value.isError`).
