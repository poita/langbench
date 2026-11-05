# webhooks

A small D library (and command-line tool) for [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signatures, plus a deterministic webhook delivery simulator with a fixed retry
schedule.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch: nothing from
`std.digest`, `std.base64` or any third-party package is used, only the D
standard library for containers and I/O.

## Layout

| path | contents |
|---|---|
| `source/webhooks/sha256.d` | incremental SHA-256 |
| `source/webhooks/hmac.d` | HMAC-SHA-256 with precomputed ipad/opad states |
| `source/webhooks/base64.d` | standard / URL-safe Base64, spec-conformant decoder |
| `source/webhooks/hex.d` | lowercase hex helpers |
| `source/webhooks/signature.d` | secrets, signing, verification |
| `source/webhooks/simulator.d`, `simparse.d`, `heap.d` | delivery simulator, block parser, scheduler heap |
| `source/webhooks/commands.d` | the stdin command-stream interpreter |
| `source/webhooks/grammar.d`, `buffer.d` | field validation, line/field views, output buffer |
| `cli/app.d` | thin CLI: stdin → `processInput` → stdout |
| `tests/*.d` | unit tests (separate from the library sources) |

## Build

Requires LDC and dub.

```sh
./build.sh          # dub build -b release --compiler=ldc2  →  bin/webhooks
dub test --compiler=ldc2
```

## Command-line use

`bin/webhooks` (or `./run.sh`) reads the whole of stdin and writes one result
per command line to stdout. It always exits 0; malformed lines print `error`.
Blank lines are ignored. Free-form byte arguments are lowercase hex (`-` means
empty).

```
$ printf 'sha256 616263\nb64enc 666f6f\nsecret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
Zm9v
31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0
```

Commands: `sha256`, `hmac`, `b64enc`, `b64urlenc`, `b64dec`, `secret`, `sign`,
`verify`, and `simulate … end` blocks (endpoints with scripted responses, then
events; the output lists every attempt and every delivery). The full grammar
and semantics are in `problems/webhooks/SPEC.md` of the task this was built
for.

## Library use

Add the package as a dependency (`dependency "webhooks" path="../webhooks"`)
and `import webhooks;`:

```d
import webhooks;

void main()
{
    Secret[] secrets;
    assert(parseSecrets(cast(const(ubyte)[]) "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", secrets));

    auto id = cast(const(ubyte)[]) "msg_p5jXN8AQM9LWM0D4loKWxJek";
    auto ts = cast(const(ubyte)[]) "1614265330";
    auto body_ = cast(const(ubyte)[]) `{"test": 2432232314}`;

    // Sign: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
    ByteSink header;
    signHeader(secrets, id, ts, body_, header);

    // Verify a received webhook at time `now`.
    auto result = verify(secrets, id, ts, header.data, body_, 1614265400);
    assert(result.ok && result.secretIndex == 0 && result.tokenIndex == 0);

    // Primitives
    ubyte[32] digest = sha256Of(cast(const(ubyte)[]) "abc");
    string b64 = encodeStandard(digest[]);
}
```

Running the simulator from code: fill a `Simulation` (`endpoints`, `events`)
or parse a block with `parseSimulateBlock`, then call `createDeliveries()`,
`run()` and `render(sink)`.

## Design notes

* Input is read in bulk; lines and fields are slices of that buffer.
* HMAC keys are prepared once (`HmacKey` stores the ipad and opad hasher
  states); the signed content `id.ts.body` is streamed, never concatenated.
* `verify` decodes each header token once and computes one MAC per secret.
* The simulator signs each delivery once at creation and schedules attempts
  with a binary min-heap of `(time, delivery)` pairs.
* All output goes to a single growable buffer written at the end.
