# webhooks

A small C++20 library for [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signatures, plus a deterministic webhook-delivery simulator and a
command-line tool that drives both from a command stream on stdin.

SHA-256, HMAC-SHA-256 and Base64 are implemented from scratch; the library
depends only on the C++ standard library (GoogleTest is needed only for the
unit tests).

## Layout

| path | contents |
|---|---|
| `include/webhooks/bytes.hpp` | `Bytes` / `ByteView` vocabulary types |
| `sha256.hpp`, `hmac.hpp` | incremental and one-shot SHA-256 / HMAC-SHA-256, constant-time compare |
| `base64.hpp`, `hex.hpp` | standard and URL-safe Base64 with a strict decoder; lowercase hex |
| `secret.hpp` | `whsec_…` secret parsing |
| `signature.hpp` | `SigningKey`, `sign_header()`, `verify()` |
| `simulator.hpp` | retry/disable delivery simulator (`Scenario` → `SimulationResult`) |
| `arguments.hpp`, `protocol.hpp` | the command language: argument grammar and `run_commands()` |
| `webhooks.hpp` | umbrella header |
| `cli/main.cpp` | thin stdin/stdout wrapper around `run_commands()` |
| `tests/` | GoogleTest unit tests |
| `examples/example.cpp` | library usage example |

## Build

Requires a C++20 compiler and CMake ≥ 3.20 (GoogleTest optional, for tests).

```sh
./build.sh                 # Release build into ./build
cd build && ctest          # run the unit tests
```

Equivalent manual steps: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
CMake options: `WEBHOOKS_BUILD_CLI` (default ON), `WEBHOOKS_BUILD_TESTS` (default ON).
`cmake --build build --target webhooks-example` builds the example.

## Command-line use

`./run.sh` (or `build/webhooks`) reads all of stdin and writes one result line
per command line; malformed input prints `error`, and the exit code is always 0.

```
$ printf 'sha256 616263\nb64enc 666f6f\nsecret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw\n' | ./run.sh
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
Zm9v
31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0
```

Commands (binary data and free text are lowercase hex, `-` meaning empty):

```
sha256 <hex>                    hmac <key-hex> <msg-hex>
b64enc <hex>                    b64urlenc <hex>            b64dec <text-hex>
secret <secret>
sign <secrets> <id> <ts> <payload-hex>
verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>
simulate                        (block: endpoint… event… end)
```

A `simulate` block:

```
simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
event msg_1 1700000000 user.created 7b7d
end
```

prints `sim <attempts> <deliveries>`, one `attempt …` line per attempt and one
`delivery …` line per delivery. The full grammar, retry schedule (5s, 5m, 30m,
2h, 5h, 10h, 10h; at most 8 attempts) and error rules are in the problem
specification (`SPEC.md`).

## Library example

```cpp
#include <iostream>
#include "webhooks/webhooks.hpp"

int main() {
  using namespace webhooks;
  std::vector<SigningKey> keys;
  keys.emplace_back(*parse_secret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"));

  std::string_view body = R"({"test": 2432232314})";
  std::string header = sign_header(keys, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", as_bytes(body));
  // header == "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="

  VerifyResult r = verify(keys, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", header,
                          as_bytes(body), /*now=*/1614265400);
  std::cout << (r.ok ? "ok" : std::string(to_string(r.error))) << "\n";
}
```

Link with `webhooks::webhooks` (e.g. `add_subdirectory(webhooks)` then
`target_link_libraries(app PRIVATE webhooks::webhooks)`). See
`examples/example.cpp` for a simulator example.

## Design notes

* `verify()` computes one MAC per secret and compares it with every decoded
  `v1` token (O(S·(B+T))); the comparison is constant-time.
* The simulator signs each delivery once, and processes attempts from a binary
  min-heap keyed by `(time, delivery number)`: O((D + A) log D).
