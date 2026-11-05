# jsoncanon

A strict JSON (RFC 8259) parser and canonical serializer in Go, written from
scratch with only the standard library (no `encoding/json`). It parses a
document, rejecting anything not strictly valid, and re-emits it in a
canonical form:

- no whitespace outside strings;
- object members sorted by key in UTF-16 code unit order, duplicate keys
  collapsed to the last occurrence;
- only `"`, `\` and U+0000–U+001F escaped (lowercase `\u00xx`); everything
  else, including `/`, is raw UTF-8;
- numbers echoed as text (never converted to floating point, so any size is
  preserved), with exponents normalized (`1E+05` → `1e5`, `1e-0` → `1e0`).

Validation is strict: well-formed UTF-8 only (no overlong forms, surrogates or
BOM), paired `\u` surrogate escapes, whitespace limited to the four JSON
characters, and nesting depth at most 512.

The design: validate the whole input as UTF-8 in one pass, parse with a single
recursive-descent pass over bytes (escape-free strings and plain numbers alias
the input), then serialize once into a single buffer. Object keys are sorted
through small handles by comparing UTF-8 bytes directly, adjusting the order of
U+E000–U+FFFF versus supplementary characters to match UTF-16.

## Build

Requires Go 1.27.1.

```
./build.sh          # writes bin/jsoncanon
go test ./...       # unit tests
```

## Command-line use

`jsoncanon` reads the whole of stdin as one document and prints one line: the
canonical form, or `invalid`. The exit status is 0 either way.

```
$ echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
{"a":"héllo/","b":null}
$ echo '[1, 2, ]' | ./run.sh
invalid
```

## Library use

```go
package main

import (
	"fmt"

	"example.com/jsoncanon"
)

func main() {
	out, err := jsoncanon.Canonicalize([]byte(`{"b":1e+05,"a":[true, null]}`))
	if err != nil {
		fmt.Println("invalid:", err) // err is a *jsoncanon.SyntaxError
		return
	}
	fmt.Println(string(out)) // {"a":[true,null],"b":1e5}

	// Inspect a document before serializing it.
	v, _ := jsoncanon.Parse([]byte(`{"k":1,"k":2}`))
	fmt.Println(v.Lookup("k").Num()) // 2 (last occurrence wins)
}
```

## Layout

| File | Responsibility |
| --- | --- |
| `canon.go` | `Canonicalize`, the one-call entry point |
| `parser.go` | UTF-8/BOM check, recursive-descent parser, strings, numbers, `Parse` |
| `utf8.go` | strict RFC 3629 validator |
| `value.go` | `Value`/`Kind` tree and accessors |
| `keyorder.go` | UTF-16-order key comparison on UTF-8 bytes |
| `serialize.go` | canonical writer, key sort and dedup, string escaping |
| `errors.go` | `SyntaxError` |
| `cmd/jsoncanon` | the command-line tool |
