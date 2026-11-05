# webhooks

A small D library and command-line tool for [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signing and verification, plus a deterministic webhook-delivery simulator with a
fixed retry schedule.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch in this repository
(no `std.digest`, no `std.base64`); only the D standard library's I/O and
containers are used. No third-party dependencies.

## Building

Requires LDC (tested with 1.41.0) and dub (1.40.0).

```sh
./build.sh                 # = dub build -b release --compiler=ldc2 ; produces bin/webhooks
dub test --compiler=ldc2   # run the unit tests
```

`./run.sh` runs the built tool from any directory.

## Command-line tool

`bin/webhooks` (or `./run.sh`) reads commands, one per line, from stdin and
writes one result per command to stdout. It always exits 0: a malformed line
prints `error`. Fields are separated by single spaces; blank lines are ignored.

Binary data and free text are hex-encoded (`-` means empty).

| command | output |
|---|---|
| `sha256 <hex>` | digest as hex |
| `hmac <key-hex> <msg-hex>` | HMAC-SHA-256 as hex |
| `b64enc <hex>` / `b64urlenc <hex>` | padded standard / unpadded URL-safe Base64 (`-` if empty) |
| `b64dec <text-hex>` | decoded bytes as hex, or `error` |
| `secret <secret>` | raw key as hex, or `error` |
| `sign <secrets> <id> <ts> <payload-hex>` | `webhook-signature` header value |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | `ok <secret-idx> <token-idx>` or `fail <reason>` |
| `simulate` … `end` | delivery simulation report |

`<secrets>` is one or more comma-separated secrets (`whsec_` + Base64, prefix
optional). Failure reasons are `missing-signature`, `invalid-timestamp`,
`timestamp-too-old`, `timestamp-too-new` and `no-match` (tolerance ±300 s).

Example:

```console
$ printf 'sha256 616263\nsign whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 7b2274657374223a20323433323233323331347d\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=
```

### Simulator

```
simulate
endpoint <ep-id> <secrets> <filter> <script>     # filter: * or type,type,...  script: 500,timeout,200
event <ev-id> <ts> <type> <payload-hex>
end
```

Each event is delivered to every endpoint whose filter matches. An attempt
consumes the next response of the endpoint's script (the last one repeats);
2xx succeeds, `410` fails the delivery and disables the endpoint, anything else
is retried up to 8 attempts at `+5s, +5m, +30m, +2h, +5h, +10h, +10h`. The
report is `sim <attempts> <deliveries>`, then one `attempt …` line per attempt in
time order and one `delivery …` line per delivery (with its signature header).
Any malformed line makes the whole block print a single `error`.

```
simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
event msg_1 1700000000 user.created 7b7d
end
```

## Library

Source layout (`source/webhooks/`):

| module | responsibility |
|---|---|
| `sha256` | incremental SHA-256 (`Sha256`, `sha256`) |
| `hmac` | HMAC-SHA-256 with precomputed pads (`HmacKey`, `hmacSha256`) |
| `base64` | encoders, strict decoder (`putStandard`, `encodeUrlSafe`, `decode`, …) |
| `hex` | hex argument codec |
| `secret` | `whsec_` secrets → keys (`decodeSecret`, `parseSecrets`) |
| `signature` | `sign`, `verify`, `VerifyResult` |
| `simulator`, `heap` | delivery simulation and its priority queue |
| `commands` | the stdin command language (`processInput`) |
| `fields`, `buffer` | grammar checks, `Bytes` views, `OutBuffer` |

`import webhooks;` re-exports everything. Inputs are byte views (`Bytes` =
`const(ubyte)[]`; `asBytes` converts a string).

```d
import std.stdio;
import webhooks;

void main()
{
    HmacKey[] keys;
    assert(parseSecrets(asBytes("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"), keys));

    auto id = asBytes("msg_p5jXN8AQM9LWM0D4loKWxJek");
    auto ts = asBytes("1614265330");
    auto body_ = asBytes(`{"test": 2432232314}`);

    string header = sign(keys, id, ts, body_);       // "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="

    auto result = verify(keys, id, ts, 1614265400, asBytes(header), body_);
    assert(result.status == VerifyStatus.ok);
    writeln(toHex(sha256(asBytes("abc"))[]));        // ba7816bf…15ad
}
```

To use it as a dependency, depend on the `library` configuration:
`dependency "webhooks" path="…" ` with `subConfiguration "webhooks" "library"`.

## Tests

Unit tests live in `tests/` (separate from the library source) and run with
`dub test --compiler=ldc2`.

## Design notes

Input is read in one bulk read and walked as views; HMAC keys are prepared once
(inner/outer pad states) and signed content is streamed into the hasher rather
than concatenated; `verify` decodes each header token once and computes one MAC
per secret; the simulator signs each delivery once and schedules attempts with
a binary min-heap keyed on `(time, delivery number)`.
