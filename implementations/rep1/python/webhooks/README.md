# webhooks

A small, dependency-free Python library for [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signing and verification, with a deterministic delivery simulator and a
line-oriented command-line tool.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch in this package;
no hash, MAC or Base64 routine from the standard library is used. Only the
standard library is required (pytest for the tests).

## Layout

| module | responsibility |
|---|---|
| `webhooks.sha256` | SHA-256 (FIPS 180-4) |
| `webhooks.hmac_sha256` | HMAC-SHA-256 (RFC 2104) |
| `webhooks.b64` | standard / URL-safe Base64 encoding, strict decoding |
| `webhooks.secret` | `whsec_` secrets → raw keys |
| `webhooks.timestamp` | canonical decimal integers |
| `webhooks.signing` | building signed content and `webhook-signature` headers |
| `webhooks.verification` | `verify()` with key rotation and a 300 s tolerance |
| `webhooks.simulator` | retry-schedule delivery simulator (heap-driven) |
| `webhooks.protocol` | the stdin command grammar |
| `webhooks.cli` | thin `main()` wrapper |

## Build and test

Python 3.14 is required. There is nothing to install.

```
./build.sh                 # byte-compiles the sources
python3 -m pytest          # run the project's tests (from this directory)
```

## Command-line use

`./run.sh` reads commands on stdin (one per line) and writes one result per
command on stdout. It always exits 0; malformed lines print `error`.

```
$ printf 'sha256 616263\nb64urlenc fbff\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
-_8
```

Commands (binary and free-form arguments are lowercase hex, `-` meaning empty):

```
sha256 <hex>                    hmac <key-hex> <msg-hex>
b64enc <hex>                    b64urlenc <hex>          b64dec <text-hex>
secret <secret>
sign <secrets> <id> <ts> <payload-hex>
verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>
simulate                        # followed by a block, terminated by `end`:
  endpoint <ep-id> <secrets> <filter> <script>
  event <ev-id> <ts> <type> <payload-hex>
  end
```

`<secrets>` is up to 16 comma-separated secrets. `verify` prints `ok <i> <j>` or
`fail <reason>`. A `simulate` block prints `sim <attempts> <deliveries>`,
the `attempt` lines, then the `delivery` lines. See the project specification
for the full grammar and output formats.

## Library example

```python
from webhooks import parse_secret, sign, verify, Endpoint, Event, simulate

key = parse_secret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
body = b'{"test": 2432232314}'

header = sign([key], "msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, body)
# 'v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE='

result = verify([key], "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", header, body, now=1614265400)
assert result.ok and str(result) == "ok 0 0"

sim = simulate(
    [Endpoint("ep", (key,), None, (500, None, 200))],   # None = timeout
    [Event("evt_1", 1700000000, "user.created", b"{}")],
)
print("\n".join(sim.lines()))
```
