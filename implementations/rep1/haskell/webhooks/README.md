# webhooks

A small Haskell library and command-line tool for [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md):
signing, verification, and a deterministic delivery simulator with a fixed retry schedule.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch in the library; it
depends only on `base`, `bytestring`, `array` and `containers` (all bundled with GHC).

## Layout

| Module | Responsibility |
|---|---|
| `Webhooks.SHA256` | FIPS 180-4 SHA-256 |
| `Webhooks.HMAC` | HMAC-SHA-256 (RFC 2104), constant-time comparison |
| `Webhooks.Base64` | standard and URL-safe encoding; strict, alphabet-agnostic decoding |
| `Webhooks.Hex` | lowercase hex and the `<hex>` protocol field |
| `Webhooks.Field` | field grammars (`<int>`, `<id>`, names), line splitting |
| `Webhooks.Secret` | `whsec_` secrets and rotation lists |
| `Webhooks.Signature` | `signatureHeader`, `verify` |
| `Webhooks.Heap` | leftist min-heap used for scheduling |
| `Webhooks.Simulator` | endpoints, events, retries, `simulate`, output rendering |
| `Webhooks.Simulator.Block` | reading and validating a `simulate` block |
| `Webhooks.Command` | the command interpreter behind the CLI |
| `Webhooks` | umbrella re-export |

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # builds and copies the executable to bin/webhooks
cabal test          # runs the hspec / QuickCheck suite
```

## Command-line use

`./run.sh` reads commands from stdin, one per line, and prints one result per
command. The exit status is always 0; malformed input prints `error`.
Free-form data (payloads, headers) is hex-encoded; `-` is the empty value.

| command | output |
|---|---|
| `sha256 <hex>` | digest in hex |
| `hmac <key-hex> <msg-hex>` | MAC in hex |
| `b64enc <hex>` / `b64urlenc <hex>` | padded standard / unpadded URL-safe Base64 |
| `b64dec <text-hex>` | decoded bytes in hex |
| `secret <secret>` | raw key in hex |
| `sign <secrets> <id> <ts> <payload-hex>` | `webhook-signature` header value |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | `ok <i> <j>` or `fail <reason>` |
| `simulate` … `end` | delivery simulation (below) |

```
$ printf 'sha256 616263\nb64enc 666f6f\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
Zm9v
```

A simulation block lists endpoints, then events:

```
simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
event msg_1 1700000000 user.created 7b7d
end
```

and prints `sim <attempts> <deliveries>`, the attempt lines in processing order,
then one delivery line per (event, endpoint) pair. Failed deliveries retry up to
eight attempts at +5s, +5m, +30m, +2h, +5h, +10h, +10h; a `410` disables the endpoint.
The full format is specified in `problems/webhooks/SPEC.md`.

## Library example

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Webhooks

main :: IO ()
main = do
  let Just keys = parseSecrets "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
      body      = "{\"test\": 2432232314}"
      header    = signatureHeader keys "msg_p5jXN8AQM9LWM0D4loKWxJek" "1614265330" body
  print header
  -- "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
  print (verify keys "msg_p5jXN8AQM9LWM0D4loKWxJek" "1614265330" header body 1614265400)
  -- Right (0,0)
  let Just ep = parseEndpointLine ["endpoint", "ep", "c2VjcmV0", "*", "500,200"]
  print (map attemptTime (resultAttempts (simulate [ep] [Event "e" 1000 "t" body])))
  -- [1000,1005]
```

`verify` returns `Left` of a `VerifyError` (`MissingSignature`, `InvalidTimestamp`,
`TimestampTooOld`, `TimestampTooNew`, `NoMatch`) or `Right (secretIndex, tokenIndex)`.
It computes one MAC per secret regardless of the number of header tokens.

## License

MIT.
