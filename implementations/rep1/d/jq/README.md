# jq (D)

A small implementation of a subset of the [jq](https://jqlang.github.io/jq/)
query language, written in D with nothing but the standard library. It
consists of

* a **library** (`source/jq/`) with its own JSON parser, JSON serializer and
  filter interpreter, and
* a thin **command-line tool** (`app/main.d`) that reads a filter and a JSON
  document from stdin and prints each result as a line of compact JSON.

The supported language and its exact semantics (evaluation order, `?`, key
ordering, number formatting, …) are those of jq 1.7 (`jq -c`) restricted to the
subset described in the problem's `SPEC.md`: paths (`.a`, `.[0]`, `.[]`,
`.[1:3]`), pipes and commas, arithmetic and comparisons, `and`/`or`, `if`,
`as` bindings, `reduce`, array and object construction, `?`, and the builtins
`empty error not length keys has type add select map sort sort_by group_by
unique reverse min max tostring tonumber`.

## Building

Requires LDC (tested with 1.41.0) and dub (1.40.0).

```sh
./build.sh          # = dub build -b release --compiler=ldc2; produces bin/jq
dub test --compiler=ldc2
```

`dub build --config=library` builds only the library.

## Command line

The first line of stdin is the filter; everything after it is the JSON
document. Every result is printed on its own line. If evaluation fails, the
results produced so far are printed, then a line `error`. The exit code is 0.

```console
$ printf '%s\n%s\n' '.users | map(select(.age >= 30) | .name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bo","age":20}]}' | ./run.sh
["ann"]
$ printf '%s\n%s\n' '[(1,2) + (10,20)], {a:(1,2)}' 'null' | ./run.sh
[11,12,21,22]
{"a":1}
{"a":2}
```

## Library

```d
import std.stdio : writeln;
import jq;

void main()
{
    // Compile once, run on any number of inputs.
    auto filter = Filter.compile(`.users | map(select(.age >= 30) | .name)`);
    auto doc = parseJson(`{"users":[{"name":"ann","age":31},{"name":"bo","age":20}]}`);

    // Collect every output ...
    foreach (result; filter.collect(doc))
        writeln(toJson(result));           // ["ann"]

    // ... or stream them; outputs delivered before an error stand.
    try
        Filter.compile(`1, 2, error, 3`).run(Value.makeNull(), (Value v) => writeln(toJson(v)));
    catch (JqError e)
        writeln("error");                   // after printing 1 and 2
}
```

Using the library from another dub project: add a dependency on this package
(`dependency "jq" path="../jq"`, with `subConfiguration "jq" "library"`).

### Layout

| Module | Responsibility |
|---|---|
| `jq` | public import of everything below that is part of the API |
| `jq.value` | `Value`, `JObject`, `ObjectBuilder`; ordering (`compare`) and equality |
| `jq.json` | `parseJson`, `toJson`, `writeJson`: JSON text ⇄ `Value` |
| `jq.filter` | `Filter`: `compile`, `run`, `collect` |
| `jq.error` | `JqException` and its subclasses `JqError` (runtime), `JqSyntaxError`, `JsonParseError` |
| `jq.lexer`, `jq.parser`, `jq.ast` | filter text → syntax tree (recursive descent) |
| `jq.interp` | the evaluator (continuation-passing, lazy, ordered) |
| `jq.ops` | indexing, slicing, arithmetic and value-level builtins |

### Design notes

* Values are immutable and shared; indexing, binding and iteration never copy.
  Objects keep insertion order, with expected O(1) lookup and a sorted key
  order that is computed at most once. `a + b` on objects/arrays appends in
  place into spare capacity when `a` is the newest version, so accumulating in
  a `reduce` is amortized linear.
* The evaluator pushes each output to a callback, so streams are lazy and the
  CLI prints results as they are produced; an error unwinds as a `JqError`.
  `?` as `try` distinguishes errors raised inside the term from errors raised
  later in the pipeline.
* Sorting is a stable comparison sort with one key evaluation per element.
* Numbers are doubles, parsed with a correctly rounded fast path (falling back
  to `strtod`) and printed as integers or the shortest `%.15g`–`%.17g` text that
  round-trips.

## Tests

`dub test --compiler=ldc2` runs the D `unittest` blocks in `source/` and the
end-to-end suite in `tests/spec_examples.d`.
