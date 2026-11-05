# webhooks

A small, dependency-free Go library for the
[Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signature scheme, plus a deterministic webhook delivery simulator and a
command-line tool that drives both from a command stream.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch in this module;
nothing from `crypto/*`, `hash/*` or `encoding/base64` is used by the library
(the unit tests use them only as an independent oracle). Only the Go standard
library is used otherwise.

## Layout

| path | responsibility |
|---|---|
| `sha256/` | incremental SHA-256 (`Hasher`, `Sum256`) |
| `hmac/` | HMAC-SHA-256 with a precomputed `Key` (ipad/opad states) |
| `base64/` | standard/URL-safe encoding and the strict-but-lenient decoder |
| `signature/` | secrets, `Sign`, `Verify` |
| `simulator/` | retry scheduler (`Run`) and text report |
| `internal/protocol/` | the command language used by the CLI |
| `cmd/webhooks/` | the command-line tool (reads stdin, writes stdout) |

## Build and test

```
./build.sh            # go build -o bin/webhooks ./cmd/webhooks
go test ./...         # unit tests
./run.sh < commands   # run the tool
```

Requires Go 1.27.1.

## Command-line tool

`webhooks` reads the entire standard input as a stream of lines and writes one
result per command to standard output. It always exits 0; malformed lines
print `error`. Binary and free-form text arguments are lowercase hex (`-` for
the empty string).

| command | output |
|---|---|
| `sha256 <hex>` | digest in hex |
| `hmac <key-hex> <msg-hex>` | tag in hex |
| `b64enc <hex>` / `b64urlenc <hex>` | padded standard / unpadded URL-safe Base64 (`-` if empty) |
| `b64dec <text-hex>` | decoded bytes in hex, or `error` |
| `secret <secret>` | raw key in hex, or `error` |
| `sign <secrets> <id> <ts> <payload-hex>` | `webhook-signature` header |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | `ok <i> <j>` or `fail <reason>` |
| `simulate` … `end` | delivery simulation report |

`<secrets>` is up to 16 comma-separated secrets, each with an optional
`whsec_` prefix. A simulation block looks like:

```
simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0 user.created 200
event msg_1 1700000000 user.created 7b7d
end
```

and prints `sim <attempts> <deliveries>`, then one `attempt` line per attempt
and one `delivery` line per delivery. The full grammar is in
`problems/webhooks/SPEC.md`.

```
$ printf 'sha256 616263\nb64enc 666f6f\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
Zm9v
```

## Library example

```go
package main

import (
	"fmt"

	"example.com/webhooks/hmac"
	"example.com/webhooks/signature"
	"example.com/webhooks/simulator"
)

func main() {
	key, err := signature.ParseSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
	if err != nil {
		panic(err)
	}
	keys := []*hmac.Key{key}
	body := []byte(`{"test": 2432232314}`)

	// Sign: the timestamp text is signed exactly as it is sent.
	header := signature.Sign(keys, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", body)
	fmt.Println(header) // v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=

	// Verify, 70 seconds later.
	m, err := signature.Verify(keys, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330",
		[]byte(header), body, 1614265400)
	fmt.Println(m, err) // {0 0} <nil>

	// Simulate deliveries with retries against scripted responses.
	res := simulator.Run(
		[]simulator.Endpoint{{ID: "ep", Keys: keys, Script: []simulator.Response{500, 200}}},
		[]simulator.Event{{ID: "ev", Type: "t", TimestampText: "1700000000", Timestamp: 1700000000, Payload: body}},
	)
	fmt.Print(string(res.AppendReport(nil)))
}
```

Verification failures are the errors `signature.ErrMissingSignature`,
`ErrInvalidTimestamp`, `ErrTimestampTooOld`, `ErrTimestampTooNew` and
`ErrNoMatch`; their `Error()` text is the reason word the CLI prints.

## Design notes

- Input is read in one go and parsed as views into the buffer; hex is decoded
  once per line, and output is accumulated in one buffer.
- `hmac.Key` stores the hasher states after the ipad and opad blocks, so a MAC
  copies two small structs and streams `id . ts . body` without concatenating.
- `signature.Verify` decodes each header token once, then computes one MAC per
  secret.
- The simulator signs each delivery once at creation and schedules attempts
  with a binary min-heap of `(time, delivery)` pairs.
