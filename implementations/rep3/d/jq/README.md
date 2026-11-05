# jq (D)

A small implementation of a subset of the [jq](https://jqlang.github.io/jq/)
filter language, written in D with only the standard library. It contains its
own JSON parser, JSON serializer and filter interpreter, and is packaged as a
reusable library plus a thin command-line tool. Semantics follow jq 1.7
(`jq -c`) for the subset described in `problems/jq/SPEC.md`.

## Design in brief

* `Value` is a 16-byte tagged struct: null/booleans/numbers are inline;
  strings and arrays are a (pointer, length) pair; objects reference an
  insertion-ordered `Obj` (entry vector, lazily built hash index above 8 keys,
  memoised code-point key order). Values are immutable and share children.
  The JSON parser slices strings and object keys straight out of the input
  buffer, so keys are shared rather than copied.
* Filters are parsed once into an AST by a recursive-descent parser and run by
  a push-style tree-walking interpreter: `eval(node, input, env, sink)` calls
  `sink` once per output using non-escaping (`scope`) delegates. Nodes that
  always yield exactly one value take a direct, callback-free fast path.
* Runtime errors are `JqError` exceptions; `?` on path operations is checked
  directly (no exception), and `try` distinguishes errors in its own term from
  errors raised downstream.
* Sorting is O(n log n) over an index permutation with the original index as
  tie-break; `sort_by`/`group_by` evaluate their key once per element.

## Layout

```
dub.sdl            package manifest (configurations: application, library, unittest)
build.sh run.sh    build / run helpers (work from any directory)
app/main.d         command-line tool
source/jq/         library
  package.d          public entry point (re-exports, `query`)
  value.d            Value, Obj, Tag
  json.d             JSON parser and serializer
  number.d           number parsing / formatting
  buffer.d           growable output buffer
  compare.d          total order and equality
  ast.d, parser.d    filter syntax tree, lexer and parser
  arith.d            operators, indexing, slicing
  builtins.d         sort/group/unique/add/keys/... implementations
  interp.d           evaluator
  errors.d           JqError, ParseError
tests/             unit tests (separate modules, run by `dub test`)
```

## Build

Requires LDC 1.41 and dub 1.40.

```
./build.sh                                  # builds bin/jq
# equivalent to: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                    # unit tests
```

## Command-line use

The tool reads stdin: the **first line is the filter**, everything after the
first newline is **one JSON document**. Each result is printed as compact
JSON on its own line. If evaluation raises an uncaught error, the results
produced so far are printed followed by a line `error`. The exit status is 0
(2 if the filter or document is malformed).

```
$ printf '.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)\n{"users":[{"name":"ann","age":31},{"name":"bob","age":20}]}' | ./run.sh
["ann"]

$ printf '.[] | .a.b?\n[{"a":{"b":1}},{"a":5},3]' | ./run.sh
1
error
```

### Supported language

Identity, `.foo`, `."foo"`, `.[e]`, `.[]`, `.[a:b]`, postfix `?`, literals,
`$var`, `e as $x | body`, `reduce`, `if/elif/else`, array and object
construction, `, | and or`, comparison, `+ - * / %`, unary minus, and the
builtins `empty error not length keys has type add select map sort sort_by
group_by unique reverse min max tostring tonumber`.

## Library use

```d
import std.stdio;
import jq;

void main()
{
    auto prog = compile(`.users | map(.name)`);
    auto doc  = parseJson(`{"users":[{"name":"ann"},{"name":"bob"}]}`);

    // Stream every output of the filter.
    run(prog, doc, (Value v) { writeln(toJson(v)); });   // ["ann","bob"]

    // Or collect everything at once.
    auto r = query(`.[] | 10 / .`, `[2, 0]`);
    assert(r.outputs == ["5"] && r.failed);              // error on the second
}
```

Public API (all re-exported from `import jq;`):

* `compile(string filter) -> Program` — throws `ParseError`.
* `parseJson(string text) -> Value` — throws `ParseError`.
* `run(Program, Value input, scope void delegate(Value) sink)` — throws
  `JqError` if evaluation fails after earlier outputs were sent to `sink`.
* `toJson(Value) -> string`, `writeJson(ref Buf, Value)` — compact output.
* `query(filter, json) -> QueryResult{outputs, failed}` — convenience wrapper.
* `Value`, `Obj`, `Tag`, `mkNull/mkBool/mkNum/mkStr/mkArr/mkObj`,
  `compare`, `equals`.
