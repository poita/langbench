# webhooks

A small D library and command-line tool for [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md):
signing and verifying webhook payloads, plus a deterministic delivery simulator
that retries failed deliveries on the standard schedule.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch; the project uses
only D's standard library (and only for I/O and containers).

## Layout

| path | contents |
|---|---|
| `source/webhooks/sha256.d` | incremental SHA-256 (`Sha256`, `sha256Of`) |
| `source/webhooks/hmac.d` | HMAC-SHA-256 with precomputed key state (`HmacKey`, `hmacSha256`) |
| `source/webhooks/base64.d` | standard / URL-safe Base64 encode, lenient-alphabet strict-padding decode |
| `source/webhooks/hex.d` | protocol hex arguments |
| `source/webhooks/secret.d` | `whsec_` secrets and secret lists |
| `source/webhooks/signature.d` | `signatureHeader`, `verify`, `VerifyResult` |
| `source/webhooks/simulator.d` | `Simulation`, retry schedule, report rendering |
| `source/webhooks/simparse.d` | validation of `simulate` block lines |
| `source/webhooks/commands.d` | the stdin command protocol (`processInput`) |
| `cli/app.d` | thin CLI: stdin in, stdout out |
| `tests/` | unit tests (separate from the library sources) |

## Build

Requires LDC and dub.

```
./build.sh                                  # or: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                    # unit tests
```

This produces `bin/webhooks-cli`.

## CLI

`./run.sh` reads the whole of stdin, one command per line, and writes one
result per command to stdout. It always exits 0; malformed lines print `error`.
Binary and free-form arguments are lowercase hex (`-` for empty).

```
$ printf 'sha256 616263\nb64enc 666f6f\nsecret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
Zm9v
31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0
```

Commands: `sha256`, `hmac`, `b64enc`, `b64urlenc`, `b64dec`, `secret`, `sign`,
`verify`, and a `simulate … end` block. The full grammar, output formats and
error rules are in the problem's `SPEC.md`.

## Library example

```d
import webhooks;

void main()
{
    // Parse a comma-separated list of secrets (key rotation).
    HmacKey[] keys;
    assert(parseSecretList(cast(const(ubyte)[]) "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", keys));

    auto id = cast(const(ubyte)[]) "msg_p5jXN8AQM9LWM0D4loKWxJek";
    auto ts = cast(const(ubyte)[]) "1614265330";
    auto body_ = cast(const(ubyte)[]) `{"test": 2432232314}`;

    // Sign: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
    string header = signatureHeader(keys, id, ts, body_);

    // Verify at time `now`; tolerance is 300 s either way.
    auto result = verify(keys, id, ts, cast(const(ubyte)[]) header, body_, 1614265400);
    assert(result.ok && result.secretIndex == 0 && result.tokenIndex == 0);

    // A late delivery reports why it failed.
    auto late = verify(keys, id, ts, cast(const(ubyte)[]) header, body_, 1614265631);
    assert(late.status == VerifyStatus.timestampTooOld);
}
```

The simulator can be driven directly through `Simulation` (`endpoints`,
`events`, `run()` returning a `SimulationReport`), or through the text protocol
with `processInput(input, output)`.

## License

MIT
