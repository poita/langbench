# webhooks

A small, dependency-free Go library implementing the
[Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signature scheme, with its cryptographic primitives written from scratch
(SHA-256, HMAC-SHA-256 and Base64 — no `crypto/*`, `hash/*` or `encoding/*`
packages are used), plus a deterministic webhook delivery simulator and a
command-line driver.

Only the Go standard library is used (and only for things like `math/bits`,
`strconv` and `io`).

## Layout

| package | responsibility |
|---|---|
| `sha256` | incremental SHA-256 (FIPS 180-4) |
| `hmac` | HMAC-SHA-256 with precomputed key state |
| `b64` | standard / URL-safe Base64 encoding, strict-but-flexible decoding |
| `hexfield` | the protocol's hex fields (`-` is the empty string) |
| `signature` | secrets (`whsec_…`), `Sign`, `Verify` |
| `sim` | retrying delivery simulator on a virtual clock |
| `commands` | the line-oriented command protocol, built on all of the above |
| `cmd/webhooks` | the thin command-line tool around `commands` |

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # writes ./bin/webhooks
go test ./...       # unit tests
```

## Command-line use

`webhooks` (or `./run.sh`) reads commands, one per line, from stdin and writes
one result per command to stdout. The exit status is always 0; malformed input
produces the single word `error`. Byte strings are lowercase hex, with `-`
standing for the empty string.

```
$ printf 'sha256 616263\nb64enc 666f6f\nsecret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
Zm9v
31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0
```

| command | output |
|---|---|
| `sha256 <hex>` | digest, hex |
| `hmac <key-hex> <msg-hex>` | MAC, hex |
| `b64enc <hex>` / `b64urlenc <hex>` | padded standard / unpadded URL-safe Base64 (`-` if empty) |
| `b64dec <text-hex>` | decoded bytes as hex, or `error` |
| `secret <secret>` | the raw key as hex |
| `sign <secrets> <id> <ts> <payload-hex>` | the `webhook-signature` header |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | `ok <secret> <token>` or `fail <reason>` |
| `simulate` | a block of `endpoint …` / `event …` lines closed by `end`; prints the attempt log and delivery summary |

The complete grammar, error rules and simulator semantics are in the problem's
`SPEC.md`.

## Library example

```go
package main

import (
	"fmt"

	"example.com/webhooks/signature"
)

func main() {
	secret, err := signature.ParseSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
	if err != nil {
		panic(err)
	}
	secrets := []*signature.Secret{secret}
	body := []byte(`{"test": 2432232314}`)

	header := signature.Sign(secrets, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", body)
	fmt.Println(header) // v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=

	m, err := signature.Verify(secrets, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330",
		header, body, 1614265400)
	fmt.Println(m, err) // {0 0} <nil>

	_, err = signature.Verify(secrets, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330",
		header, body, 1614266000)
	fmt.Println(err) // timestamp-too-old
}
```

Simulating deliveries:

```go
ep := sim.Endpoint{ID: "ep", Secrets: secrets, Wildcard: true,
	Script: []sim.Response{500, sim.Timeout, 200}}
ev, _ := sim.NewEvent("msg_1", "1700000000", "user.created", []byte("{}"))
result := sim.Run([]sim.Endpoint{ep}, []sim.Event{ev})
os.Stdout.Write(result.AppendReport(nil))
```

## Design notes

* SHA-256 and HMAC hashers are plain values; an HMAC `Key` stores the hasher
  states after the ipad/opad blocks, so each MAC copies them rather than
  rehashing the key. The signed content (`id.ts.body`) is streamed, never
  concatenated.
* `Verify` decodes each header token once and computes one MAC per secret.
* The simulator keeps `(time, delivery)` pairs in a hand-written binary
  min-heap, signs each delivery once at creation, and writes its report into a
  single append buffer.
