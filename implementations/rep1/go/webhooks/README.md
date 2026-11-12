# webhooks

A small Go library for the [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signature scheme, plus a deterministic delivery simulator and a line-oriented
command-line tool. SHA-256, HMAC-SHA-256 and Base64 are implemented from
scratch; the standard library's hash, MAC and Base64 packages are not used
(`encoding/hex` appears only in tests). It has no dependencies beyond the Go
standard library.

## Layout

| package | role |
|---|---|
| `example.com/webhooks/sha256` | SHA-256 (FIPS 180-4), one-shot and streaming |
| `example.com/webhooks/hmac` | HMAC-SHA-256 (RFC 2104), constant-time `Equal` |
| `example.com/webhooks/b64` | standard (padded) and URL-safe (unpadded) Base64, strict decoder |
| `example.com/webhooks` | secrets, signing, verification with key rotation |
| `example.com/webhooks/simulate` | retry/delivery simulator (binary-heap scheduler) |
| `example.com/webhooks/protocol` | the CLI command language, as a reusable `Run(io.Reader, io.Writer)` |
| `cmd/webhooks` | the thin `main` over `protocol` |

## Build and test

```
./build.sh          # produces bin/webhooks
go test ./...
```

Requires Go 1.27+.

## CLI

`./run.sh` reads commands from stdin, one per line, and writes one result per
command to stdout. It always exits 0; a malformed command prints `error`.
Binary and free-form arguments are lowercase hex, with `-` for the empty
string.

| command | output |
|---|---|
| `sha256 <hex>` | digest in hex |
| `hmac <key-hex> <msg-hex>` | MAC in hex |
| `b64enc <hex>` / `b64urlenc <hex>` | padded standard / unpadded URL-safe Base64 (`-` if empty) |
| `b64dec <text-hex>` | decoded bytes in hex, or `error` |
| `secret <secret>` | raw key in hex, or `error` |
| `sign <secrets> <id> <ts> <payload-hex>` | `webhook-signature` header value |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | `ok <secret> <token>` or `fail <reason>` |
| `simulate` | a block of `endpoint …` / `event …` lines ended by `end`; prints `sim A D`, the attempts, then the deliveries |

`<secrets>` is a comma-separated list of up to 16 secrets (`whsec_` prefix
optional). Failure reasons: `missing-signature`, `invalid-timestamp`,
`timestamp-too-old`, `timestamp-too-new`, `no-match`.

```
$ printf 'sign whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 7b2274657374223a20323433323233323331347d\n' | ./run.sh
v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=
```

### Simulator blocks

```
simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200
event msg_1 1700000000 user.created 7b7d
end
```

Each endpoint has a filter (`*` or event types) and a script of responses
(status codes or `timeout`) consumed one per attempt, the last one repeating.
A delivery makes up to 8 attempts at `t, t+5, t+305, t+2105, t+9305, t+27305,
t+63305, t+99305`; a 2xx response delivers it, 410 fails it and disables its
endpoint, and anything else is retried. See `testdata/simulate_example.*` for
a full input and output.

## Library example

```go
key, _ := webhooks.ParseSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
body := []byte(`{"test": 2432232314}`)

header := webhooks.SignHeader([][]byte{key}, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", body)
// v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=

m, err := webhooks.Verify([][]byte{key}, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", header, body, time.Now().Unix())
// m.Secret, m.Token identify the matching key and header token;
// err is one of webhooks.ErrTimestampTooOld, ErrNoMatch, ...
```

Running the simulator directly:

```go
res := simulate.Run(simulate.Config{
	Endpoints: []simulate.Endpoint{{ID: "a", Keys: [][]byte{key}, Script: []simulate.Response{{Code: 500}, {Code: 200}}}},
	Events:    []simulate.Event{{ID: "e1", Timestamp: "1700000000", Time: 1700000000, Type: "x", Payload: body}},
})
for _, a := range res.Attempts { fmt.Println(a.Time, a.Outcome, a.Code) }
```
