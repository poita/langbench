# toml

A from-scratch **TOML 1.0.0** parser and serializer in Go, with no dependencies
beyond the standard library, plus a small command-line tool that converts
between TOML and *tagged JSON* (the interchange format of the
[toml-test](https://github.com/toml-lang/toml-test) suite).

- **Decode**: TOML text → tagged JSON (compact, key-sorted), or `error` if the
  document is not valid TOML 1.0.0.
- **Encode**: tagged JSON → canonical TOML, such that `decode(encode(x)) == x`.

## Layout

| Path                | Contents                                                       |
|---------------------|----------------------------------------------------------------|
| `node.go`           | `Node` tree, `Kind`, constructors and accessors                |
| `decode.go`         | `Parse`, statement loop, keys, table-resolution rules          |
| `values.go`         | value dispatch, arrays, inline tables                          |
| `strings.go`        | the four string forms and escapes                              |
| `scalar.go`, `datetime.go` | integers, floats, booleans, date-times                  |
| `jsonout.go`, `jsonin.go`  | tagged JSON writer / reader                             |
| `encode.go`         | canonical TOML writer                                          |
| `cmd/toml`          | the command-line tool                                          |

## Build

```sh
./build.sh        # builds bin/toml with `go build`
go test ./...     # unit tests
```

Requires Go 1.27 or newer. `run.sh` runs the built binary from any directory.

## Command line

Input is read from stdin. The first line is the mode, the rest is the document:

```sh
printf 'decode\nname = "Tom"\n[db]\nports = [8001, 8002]\n' | ./run.sh
# {"db":{"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"name":{"type":"string","value":"Tom"}}

printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
# a = 1
```

Decode prints one line of tagged JSON, or `error` for an invalid document.
Encode prints canonical TOML. The exit code is 0 on success.

### Output conventions

- Scalars are `{"type":T,"value":TEXT}` with `T` one of `string`, `integer`,
  `float`, `bool`, `datetime`, `datetime-local`, `date-local`, `time-local`.
- Integers are printed in decimal; floats as exactly 17 significant digits in
  scientific notation (`%.16e`), or `inf`, `-inf`, `nan`.
- Date-times are handled textually: separator normalised to `T`, trailing zeros
  of the fraction removed, `Z`/`z`/`±00:00` written as `Z`.
- Canonical TOML: pairs first (sorted), then sub-tables and arrays of tables
  with headers, separated by blank lines.

## Library

```go
package main

import (
	"fmt"
	"log"

	"github.com/example/toml"
)

func main() {
	root, err := toml.Parse([]byte("title = \"demo\"\n[server]\nport = 8080\n"))
	if err != nil {
		log.Fatal(err) // *toml.SyntaxError with Line, Offset and Msg
	}

	server, _ := root.Get("server")
	port, _ := server.Get("port")
	n, _ := port.Int()
	fmt.Println(n) // 8080

	fmt.Println(string(root.AppendJSON(nil))) // tagged JSON
	fmt.Print(string(root.AppendTOML(nil)))   // canonical TOML

	// Trees can also be built by hand or read from tagged JSON.
	t := toml.NewTable()
	t.Set("name", toml.NewString("x"))
	t.Set("tags", toml.NewArray(toml.NewInt(1), toml.NewBool(true)))
	fmt.Print(string(t.AppendTOML(nil)))
}
```

Main entry points: `Parse`, `ParseJSON`, `(*Node).AppendJSON`,
`(*Node).AppendTOML`, and the `Node` accessors (`Kind`, `Get`, `Keys`, `Len`,
`Index`, `Text`, `Int`, `Float`, `Bool`). See the package documentation
(`go doc ./...`).
