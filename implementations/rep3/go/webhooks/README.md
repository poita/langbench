# webhooks

A small, dependency-free Go library for the
[Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signature scheme, plus a deterministic webhook delivery simulator and a
command-line tool that drives both from a command stream on stdin.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch in this
repository; nothing from `crypto/*` or `encoding/base64` is used. Only the Go
standard library is imported otherwise.

## Layout

| package | responsibility |
|---|---|
| `webhooks/sha256` | incremental SHA-256 (FIPS 180-4); `Digest` is a copyable value |
| `webhooks/hmac` | HMAC-SHA-256 with precomputed key states and streamed message parts |
| `webhooks/base64` | standard (padded) and URL-safe (unpadded) encoding; lenient single decoder |
| `webhooks/hexcodec` | lowercase hex, and the `-` = empty-bytes argument convention |
| `webhooks/signature` | secrets (`whsec_…`), signing, verification with key rotation |
| `webhooks/sim` | delivery simulator: event fan-out, signing, retry schedule, scripted endpoints |
| `webhooks/internal/cli` | the line-oriented command language (used by the tool) |
| `webhooks/cmd/webhooks` | the command-line tool: stdin in, stdout out |

## Build and test

Requires Go 1.27.1.

```sh
./build.sh          # writes bin/webhooks (go build -o bin/webhooks ./cmd/webhooks)
go test ./...       # unit tests
./run.sh < commands.txt
```

`run.sh` can be invoked from any directory.

## Command-line tool

`webhooks` reads all of stdin, runs one command per line, and prints one result
per command (a `simulate` block prints several lines). Malformed input always
yields the single word `error`; the exit status is always 0. Blank lines are
ignored. Byte strings are written as lowercase hex, with `-` for the empty
string.

| command | output |
|---|---|
| `sha256 <hex>` | hex digest |
| `hmac <key-hex> <msg-hex>` | hex MAC |
| `b64enc <hex>` / `b64urlenc <hex>` | padded standard / unpadded URL-safe Base64, `-` if empty |
| `b64dec <text-hex>` | hex of the decoded bytes, or `error` |
| `secret <secret>` | hex of the raw key |
| `sign <secrets> <id> <ts> <payload-hex>` | `webhook-signature` header value |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | `ok <secret> <token>` or `fail <reason>` |
| `simulate` … `endpoint …` / `event …` … `end` | attempt and delivery report |

```
$ printf 'sha256 616263\nsign whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_1 1614265330 7b7d\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
v1,...
```

A simulation:

```
simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200
event msg_1 1700000000 user.created 7b7d
end
```

prints `sim <attempts> <deliveries>`, one `attempt …` line per attempt in
processing order, then one `delivery …` line per delivery. A delivery makes at
most 8 attempts, at `t, t+5, t+305, t+2105, t+9305, t+27305, t+63305, t+99305`;
a `410` response disables the endpoint.

## Library example

```go
package main

import (
	"fmt"

	"webhooks/signature"
	"webhooks/sim"
)

func main() {
	secrets, err := signature.ParseSecrets([]byte("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"))
	if err != nil {
		panic(err)
	}
	id, ts, body := []byte("msg_p5jXN8AQM9LWM0D4loKWxJek"), []byte("1614265330"), []byte(`{"test": 2432232314}`)

	header := signature.Sign(secrets, id, ts, body)
	fmt.Println(string(header)) // v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=

	res := signature.Verify(secrets, id, ts, 1614265400, header, body)
	fmt.Println(res.OK, res.Secret, res.Token) // true 0 0

	// Simulate delivering one event to a flaky endpoint.
	var b sim.Builder
	b.AddEndpoint([][]byte{[]byte("ep"), []byte("whsec_c2VjcmV0"), []byte("*"), []byte("500,200")})
	b.AddEvent([][]byte{[]byte("ev"), []byte("1700000000"), []byte("user.created"), []byte("7b7d")})
	cfg, _ := b.Config()
	fmt.Print(string(sim.Run(cfg).AppendTo(nil)))
}
```

Notes on the API: `signature.Verify` takes the id, timestamp text, header and
body exactly as received and checks, in order, the header, the timestamp format,
the ±300 s tolerance and finally the signatures (each secret's MAC is computed
once, each header token decoded once). Signed content is streamed through the
HMAC and never concatenated. `sim` types hold byte slices that may alias the
buffer they were parsed from.
