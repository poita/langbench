# protowire

A small, dependency-free Rust library and command-line tool that converts
between the Protocol Buffers wire format (proto3 semantics) and a canonical
text form, driven by a runtime message schema.

* **Decode**: hex bytes → canonical text such as `{a: 1, b: "x", c: [1, 2]}`.
* **Encode**: text → canonical (deterministic, minimal) wire bytes as hex.

Unknown fields, wrong-wire-type fields and groups are skipped, repeated
numeric fields accept packed and unpacked forms, repeated sub-messages merge,
and malformed input is reported as an error rather than a panic.
Decoding is linear in the payload and encoding linear in the output,
independent of nesting depth.

## Building

```sh
./build.sh            # or: cargo build --release
```

The only requirement is a Rust toolchain (developed with 1.96); there are no
third-party dependencies. The binary is `target/release/protowire`.

## Command-line use

`./run.sh` (or the binary directly) reads everything from stdin and writes
one line to stdout per request. It always exits 0; a malformed request yields
the line `error`.

```
<schema>
--
<request>
<request>
...
```

The schema is a list of `message Name { [repeated] type name = number; ... }`
definitions (scalar types `int32 int64 uint32 uint64 sint32 sint64 bool
fixed32 fixed64 sfixed32 sfixed64 string bytes`, or any message name,
including recursive ones). A line consisting of exactly `--` ends it. Each
request is either:

* `decode <Message> <lowercase-hex>` (just `decode <Message>` for no bytes), or
* `encode <Message> <text>`.

Example (the expected output is shown after the command):

```console
$ printf 'message A { int32 x = 1; repeated string s = 2; }\n--\nencode A {s: ["hi"], x: 300}\ndecode A 08ac0212026869\n' | ./run.sh
08ac0212026869
{x: 300, s: ["hi"]}
```

The text form is `{name: value, ...}` with integers in decimal, `true`/`false`,
strings in `"..."` with `\" \\ \n \r \t \xHH` escapes, bytes as `x"00ff"`,
sub-messages as `{...}` and repeated fields as `[a, b]`. `decode` prints
fields in field-number order and omits defaults; `encode` accepts any order,
optional spaces, and explicit defaults. See the specification for details.

## Library use

```rust
use protowire::Schema;

let schema = Schema::parse(
    "message Inner { sint32 v = 1; }
     message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }",
)?;

// text -> bytes
let bytes = schema.encode_from_text("Outer", r#"{d: {v: -5}, a: 1, b: "x", c: [1, 2]}"#)?;
assert_eq!(protowire::hex::encode(&bytes), "08011201781a02010222020809");

// bytes -> text
let text = schema.decode_to_text("Outer", &bytes)?;
assert_eq!(text, r#"{a: 1, b: "x", c: [1, 2], d: {v: -5}}"#);
# Ok::<(), protowire::Error>(())
```

For finer control use `Schema::message_id`, `Schema::decode` /
`Schema::encode` (which work on a `Message` value tree), `Schema::parse_text`
and `Schema::render`. To process a whole request document as the CLI does, use
`protowire::session::run`.

### Modules

| module | responsibility |
|---|---|
| `schema` | schema parsing and type resolution |
| `wire` | varints, zigzag, tags, bounds-checked `Reader` |
| `value` | the `Message` / `Value` tree |
| `hex` | lowercase hex |
| `session` | the batch request protocol (used by the CLI) |
| `error` | the shared `Error` type |

Decoding, text rendering, text parsing and encoding are implemented as methods
on `Schema` (in private modules `decode`, `render`, `parse`, `encode`).

## Tests

```sh
cargo test
```

runs unit tests in each module, integration tests of the batch protocol and
the CLI binary, and the documentation examples.
