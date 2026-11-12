# webhooks

A dependency-free Rust implementation of the
[Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signature scheme, with a deterministic delivery simulator. SHA-256, HMAC-SHA-256
and Base64 are implemented from scratch; only the Rust standard library is used.

It ships as

* a library (`webhooks`) with modules `sha256`, `hmac`, `base64`, `hex`,
  `secret`, `signature`, `simulator` and `protocol`, and
* a thin command-line tool that reads a command stream on stdin and writes
  results to stdout.

## Build

```sh
cargo build --release      # or ./build.sh
```

The binary is `target/release/webhooks` (`./run.sh` runs it from any directory).

## Command-line usage

Input is a sequence of space-separated command lines; byte strings are
lowercase hex (`-` means empty). Every malformed line prints `error`; the exit
code is always 0.

```text
sha256 <hex>                                  hmac <key-hex> <msg-hex>
b64enc <hex>   b64urlenc <hex>                b64dec <text-hex>
secret <secret>
sign <secrets> <id> <ts> <payload-hex>
verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>
simulate / endpoint <id> <secrets> <filter> <script> / event <id> <ts> <type> <payload-hex> / end
```

```console
$ printf 'sha256 616263\nsign whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 7b2274657374223a20323433323233323331347d\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=
```

`simulate` signs each (event, endpoint) delivery once and replays it against
scripted endpoint responses with the retry schedule 5s, 5m, 30m, 2h, 5h, 10h,
10h (at most 8 attempts); a `410` disables the endpoint. See `SPEC.md` of the
task for the full grammar.

## Library example

```rust
use webhooks::{sign_header, verify, Secret, VerifyOutcome};

let secret = Secret::parse("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw").unwrap();
let body = br#"{"test": 2432232314}"#;

let header = sign_header(&[secret.clone()], "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", body);
assert_eq!(header, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");

let result = verify(&[secret], "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330",
                    1614265400, header.as_bytes(), body);
assert_eq!(result, VerifyOutcome::Ok { secret: 0, token: 0 });
```

`verify` computes one MAC per secret (not per header token), accepts a
5-minute clock skew in either direction, and reports the first matching
(secret, token) pair. The simulator is available as `webhooks::simulate`, and
the whole command protocol as `webhooks::run_commands`.

## Tests

```sh
cargo test
```

Unit tests live beside each module, `tests/` holds integration tests (library
API and the compiled binary), and the public examples are doctests.
