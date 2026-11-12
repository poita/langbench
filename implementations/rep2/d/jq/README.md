# jq-d

An implementation of a subset of the [jq](https://jqlang.github.io/jq/) filter
language in D, with no dependencies beyond the standard library. It consists of

* a reusable library (`source/jq/`): a hand-written JSON parser and serializer,
  a filter parser, and a lazy, generator-based tree-walking interpreter;
* a thin command-line tool (`app/main.d`) on top of it.

The semantics follow jq 1.7 (`jq -c`) for the supported subset: paths and
slices, `?`/try, `|` `,` arithmetic, comparisons, `and`/`or`, `if`/`elif`,
`as` bindings, `reduce`, object/array construction, and the builtins `empty
error not length keys has type add select map sort sort_by group_by unique
reverse min max tostring tonumber`. Objects keep insertion order.

## Build

Requires LDC (tested with 1.41.0) and dub (1.40.0).

```sh
./build.sh          # = dub build -b release --compiler=ldc2 --config=application
dub test --compiler=ldc2   # run the unit tests
```

The binary is `./jq`.

## Command line

`./run.sh` (or `./jq`) reads all of stdin. The first line is the filter, the
rest is one JSON document. Every result is printed as one line of compact JSON.
If evaluation raises an uncaught error, the results produced so far are printed,
followed by a line `error`. The exit code is always 0.

```console
$ printf '%s\n%s' '.users | map(select(.age >= 30) | .name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bo","age":20}]}' | ./run.sh
["ann"]
```

## Library

```d
import std.stdio : writeln;
import jq;

void main()
{
    auto filter = Filter.compile(".users | map(select(.age >= 30) | .name)");
    auto doc = parseJson(`{"users":[{"name":"ann","age":31},{"name":"bo","age":20}]}`);

    // collect all results (throws JqError on a runtime error)
    foreach (result; filter.collect(doc))
        writeln(toJson(result));          // ["ann"]

    // or stream them; results before an error are still delivered
    try
        filter.run(doc, (Value v) { writeln(toJson(v)); });
    catch (JqError e) { writeln("error"); }

    // one-shot helper
    auto results = query(".[] | . * 2", "[1, 2.5]");   // 2, 5
}
```

Modules: `jq.value` (values, ordering), `jq.json` (parse/serialize), `jq.lexer`,
`jq.parser`, `jq.ast` (filter syntax), `jq.ops` (arithmetic, paths, builtins),
`jq.interp` (`Filter`, evaluation), `jq.errors`. `import jq;` re-exports the
public API. `Filter.compile` throws `FilterSyntaxError`, `parseJson` throws
`JsonException`, and evaluation throws `JqError`.

## Design notes

* Values are immutable and shared, never deep-copied; objects are
  insertion-ordered with an open-addressing index, and cache their sorted key
  order.
* Evaluation is push-based (callbacks per output), so generators are plain
  nested loops and laziness/ordering follow directly. `try` re-raises errors
  coming from downstream of the protected term.
* Sorting is a stable comparison sort with one key evaluation per element.
