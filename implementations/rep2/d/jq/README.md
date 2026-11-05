# jq (D)

A small implementation of a subset of the [jq](https://jqlang.github.io/jq/)
language in D, using only the standard library (no JSON or jq library). It has
three parts:

- **`jq` library** (`source/jq/`): JSON parser and serialiser, filter parser,
  and a push-style tree-walking interpreter with jq 1.7 semantics.
- **`jq` command-line tool** (`app/main.d`): reads one filter line and one JSON
  document on stdin, prints each result as a line of compact JSON.
- **Unit tests** (`tests/`), kept apart from the library sources.

## Build

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # = dub build -b release --compiler=ldc2; produces bin/jq
dub test --compiler=ldc2
```

## Command-line use

`./run.sh` (or `bin/jq`) reads stdin. **Line 1 is the filter; everything after
the first newline is a single JSON document.**

```sh
$ printf '%s\n%s\n' '.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bob","age":20},{"name":"cy","age":30}]}' | ./run.sh
["cy","ann"]
```

- Every result is printed as compact JSON (object keys in insertion order),
  one per line.
- If evaluation raises an uncaught error, the results produced before it are
  printed, then a line `error`, and evaluation stops. The exit status is
  always 0; diagnostics go to stderr.

### Supported language

Identity and paths (`.`, `.a`, `."a b"`, `.[i]`, `.[]`, `.[a:b]`, with `?`),
literals, variables (`E as $x | body`, `reduce SRC as $x (INIT; UPDATE)`),
`,` `|`, arithmetic `+ - * / %`, comparisons, `and` `or`, `if/elif/else/end`,
array and object construction (`{a, "b": 1, (k): v, $x}`), `try`-style `?`, and the
builtins `empty error error(f) not length keys has(k) type add select(f)
map(f) sort sort_by(f) group_by(f) unique reverse min max tostring tonumber`.
Key order, generator order and error behaviour follow jq 1.7.1; see
`problems/jq/SPEC.md` for the exact rules.

## Library use

Add the package as a dependency (`dependency "jq" path="../jq"` with
`subConfiguration "jq" "library"`) and `import jq;`.

```d
import std.stdio : writeln;
import jq;

void main()
{
    auto doc = parseJson(`{"users":[{"name":"ann","age":31},{"name":"bob","age":20}]}`);
    auto prog = new Program(`.users[] | select(.age > 25) | {name, next: (.age + 1)}`);

    JqError err;
    bool ok = prog.run(doc, (Value v) {
        writeln(toJson(v));          // {"name":"ann","next":32}
        return true;                 // return false to stop early
    }, err);
    if (!ok)
        writeln("error: ", err.message);

    // Or collect everything (throws JqException on error):
    foreach (v; prog.runAll(doc))
        writeln(toJson(v));
}
```

### Modules

| Module | Responsibility |
|---|---|
| `jq.value`  | `Value` (16-byte tagged union; scalars inline), `JStr`, `JArray`, `JObject` (insertion-ordered, hash-indexed when large), `compare` (jq total order) |
| `jq.json`   | `parseJson`, `toJson`, `writeJson`, number/string formatting |
| `jq.lexer`  | `tokenize`, `ParseException` |
| `jq.ast`    | `Node`, `NodeKind`, `Builtin` |
| `jq.parser` | `parseFilter`: recursive descent; variables resolved at parse time |
| `jq.interp` | `Program` (compile + run), `Interpreter` (the evaluator) |
| `jq.runner` | `runSpecInput`: the stdin contract as a function |
| `jq`        | `package.d`, re-exports everything |

## Design notes

- Values are immutable and shared by reference; an operation that "changes" a
  value builds a new top-level container sharing its children. Only private
  builders (an object being constructed or merged) are mutated.
- Objects are an entry vector plus, above 12 keys, an open-addressing hash
  index. The JSON parser interns key strings. The code-point-sorted key order
  is computed lazily once per object and memoised, so comparison allocates
  nothing.
- Evaluation is callback-based: `eval(node, input, env, sink)` calls `sink`
  per output. Sinks are `scope` delegates (no heap closures); the variable
  environment is a linked list of stack-allocated nodes. Errors are returned
  as a `false` status with the error recorded in the interpreter; `try`/`?`
  tell errors in their own term from errors raised downstream. Path `?`
  operations check their failure condition directly instead of raising.
  Single-output nodes (paths, arithmetic, most builtins) take a
  callback-free fast path.
- Sorting decorates with keys once and sorts an index permutation with the
  original index as tie-break; `add` folds into one builder.
- The CLI raises the GC's minimum pool size because filters such as
  `reduce ... (. + [x])` allocate large short-lived arrays.

## Layout

```
dub.sdl  build.sh  run.sh
source/jq/   value.d json.d lexer.d ast.d parser.d interp.d runner.d package.d
app/main.d
tests/       helpers.d test_value.d test_json.d test_parser.d test_interp.d test_runner.d
```
