# webhooks

A small Clojure library for [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signatures and a deterministic webhook delivery simulator, with a
line-oriented command-line tool on top.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch in this project
(no hash, MAC or Base64 routines from any library or the JDK). It depends only
on Clojure itself; `test.check` and the Cognitect test-runner are used for tests.

## Requirements

Clojure 1.12.6 (the `clojure` CLI) on a recent JDK (developed on Java 27).

## Build

```
./build.sh
```

AOT-compiles the CLI into `classes/` and records the classpath in `.cp`.
`build.sh` and `run.sh` can be run from any directory.

## Command-line use

```
./run.sh < commands.txt
```

Reads commands from stdin, one per line, and prints one result per command.
Free-form byte arguments are lowercase hex (`-` means empty). Malformed input
prints `error`; the exit status is always 0.

| command | output |
|---|---|
| `sha256 <hex>` | digest in hex |
| `hmac <key-hex> <msg-hex>` | MAC in hex |
| `b64enc <hex>` / `b64urlenc <hex>` | padded standard / unpadded URL-safe Base64 (`-` if empty) |
| `b64dec <text-hex>` | decoded bytes in hex, or `error` |
| `secret <secret>` | raw key in hex, or `error` |
| `sign <secrets> <id> <ts> <payload-hex>` | `webhook-signature` header value |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | `ok <i> <j>` or `fail <reason>` |
| `simulate` | a block of `endpoint` / `event` lines ended by `end`; prints the delivery log |

```
$ printf 'sha256 616263\nsign whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_1 1614265330 7b7d\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
v1,...
```

The complete protocol — argument grammars, `simulate` block syntax, retry
schedule and output format — is specified in `problems/webhooks/SPEC.md`.

## Library use

```clojure
(require '[webhooks.signature :as sig]
         '[webhooks.simulator :as sim]
         '[webhooks.bytes :as bytes]
         '[webhooks.base64 :as b64])

(def key (sig/parse-secret "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"))
(def body (bytes/utf8 "{\"test\": 2432232314}"))

;; Sign
(sig/signature-header [key] "msg_p5jXN8AQM9LWM0D4loKWxJek" "1614265330" body)
;; => "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="

;; Verify
(sig/verify [key] {:id "msg_p5jXN8AQM9LWM0D4loKWxJek"
                   :timestamp "1614265330"
                   :signature "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
                   :body body
                   :now 1614265400})
;; => {:ok true, :secret 0, :token 0}

;; Simulate deliveries with retries
(sim/simulate [{:id "ep" :keys [key] :filter nil :script [500 :timeout 200]}]
              [{:id "evt_1" :timestamp 1700000000 :type "user.created" :payload body}])
;; => {:attempts [...] :deliveries [...]}
```

### Modules

| namespace | responsibility |
|---|---|
| `webhooks.sha256` | `digest` |
| `webhooks.hmac` | `hmac-sha256` |
| `webhooks.base64` | `encode`, `encode-url`, `decode` (strict; either alphabet, never mixed) |
| `webhooks.hex`, `webhooks.bytes` | hex codec and byte-array helpers |
| `webhooks.signature` | `parse-secret`, `signature-header`, `verify`, `parse-timestamp` |
| `webhooks.simulator` | `simulate`, `retry-delays` |
| `webhooks.fields`, `webhooks.block`, `webhooks.commands` | protocol parsing and execution used by the CLI |
| `webhooks.cli` | `-main` |

## Tests

```
clojure -M:test
```

From the repository root, the end-to-end suite is
`webhooks/build.sh && python3 run_tests.py webhooks -- webhooks/run.sh`.
