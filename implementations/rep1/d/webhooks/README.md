# webhooks

A small D library and command-line tool for [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md):

* **SHA-256, HMAC-SHA-256 and Base64** (standard and URL-safe), written from
  scratch — no hash, MAC or Base64 routine from Phobos is used;
* the **signature scheme**: `whsec_` secrets, signing, key rotation, and
  verification with timestamp tolerance;
* a deterministic **delivery simulator** that signs events and retries failed
  deliveries on a fixed schedule (5s, 5m, 30m, 2h, 5h, 10h, 10h).

Only the D standard library is used (for containers/strings/IO plumbing); tests
use D's built-in `unittest`.

## Build

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # = dub build -b release --compiler=ldc2  → bin/webhooks
dub test --compiler=ldc2
```

## Command-line tool

`bin/webhooks` (or `./run.sh`) reads commands from stdin, one per line, and
writes one result per command to stdout. The exit code is always 0; malformed
input yields the single word `error`.

| command | output |
|---|---|
| `sha256 <hex>` | digest as hex |
| `hmac <key-hex> <msg-hex>` | MAC as hex |
| `b64enc <hex>` / `b64urlenc <hex>` | padded standard / unpadded URL-safe Base64 (`-` if empty) |
| `b64dec <text-hex>` | decoded bytes as hex (`-` if empty), or `error` |
| `secret <secret>` | the raw key as hex, or `error` |
| `sign <secrets> <id> <ts> <payload-hex>` | `webhook-signature` header value |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | `ok <secret> <token>` or `fail <reason>` |
| `simulate` … `end` | a delivery-simulation report |

Byte strings are lowercase hex, with `-` for the empty string. `<secrets>` is a
comma-separated list of up to 16 secrets (`whsec_` prefix optional).
A simulation block looks like

```
simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200
event msg_1 1700000000 user.created 7b7d
end
```

and prints `sim <attempts> <deliveries>`, one `attempt …` line per attempt in
processing order, then one `delivery …` line per delivery. The full format is
in the problem specification.

```sh
$ printf 'sha256 616263\nb64urlenc fbff\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
-_8
```

## Library

Source layout (`source/webhooks/`):

| module | responsibility |
|---|---|
| `sha256`, `hmac`, `base64`, `hex` | primitives |
| `secret`, `signature` | secrets, signing, verification |
| `heap`, `simulator` | priority queue and delivery simulator |
| `fields`, `blockparser`, `protocol` | argument validation and the command interpreter |

`import webhooks;` pulls in everything. The CLI is the thin `app/main.d`.

```d
import std.stdio;
import webhooks;

void main()
{
    // Sign a message.
    Secret secret;
    assert(Secret.parse("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", secret));
    auto id = cast(const(ubyte)[]) "msg_p5jXN8AQM9LWM0D4loKWxJek";
    auto ts = cast(const(ubyte)[]) "1614265330";
    auto body_ = cast(const(ubyte)[]) `{"test": 2432232314}`;

    string header = signatureHeader([secret], id, ts, body_);
    writeln(header); // v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=

    // Verify it 70 seconds later.
    auto r = verify([secret], id, ts, cast(const(ubyte)[]) header, body_, 1614265400);
    writeln(r.ok, " ", r.secretIndex, " ", r.tokenIndex); // true 0 0

    // Primitives.
    writeln(toHex(sha256(cast(const(ubyte)[]) "abc")));
}
```

## Tests

`dub test --compiler=ldc2` runs the `unittest` blocks in each module: published
test vectors for the primitives (NIST/FIPS, RFC 4231, the Standard Webhooks
vector), edge cases for Base64 and the protocol grammar, and simulator
scenarios.

## Design notes

* `verify` computes one HMAC per secret and decodes each header token once, so
  its cost is O(S·(B + T)).
* Each secret's key schedule is absorbed once (`Secret.keyed`); each delivery is
  signed once when the delivery is created.
* The simulator uses a binary min-heap keyed by `(time, delivery number)`,
  holding at most one pending attempt per delivery: O(log D) per step.
