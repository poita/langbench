# webhooks performance benchmark

Regenerate with `python3 gen_bench.py` (fixed seeds; expected outputs come from
`reference/main.py`, about 13 minutes in total). Run with
`python3 run_tests.py webhooks --tests-dir problems/webhooks/bench -- <impl>/run.sh`.

- `001_gateway_sign_verify` — 380 sign/verify/sha256 commands over the real
  GitHub payloads in `corpus/` (1-32 KB each, ~24 KB per hex-encoded line on average), under
  key-rotation sets of 4-16 secrets. It measures hex parsing plus SHA-256/HMAC
  throughput, the hot path of any webhook gateway. Verify headers carry only
  one or two signatures, so implementations that try every (secret, token)
  pair are not punished much compared with ones that compute each secret's
  HMAC once.
- `002_simulate_fanout` — one `simulate` block that broadcasts 150 GitHub events
  to 64 subscribers (the endpoint limit), most with `*` or broad filters and 1-3
  secrets, with healthy, flaky, dead and 410 scripts. It measures delivery
  creation and signing at fan-out: about 5,700 deliveries and 10,300 attempts,
  each delivery signed over a ~12 KB body with every endpoint secret.
- `003_dispatcher_mixed` — 5,000 mixed small API commands (verify, sign, secret,
  b64enc/b64dec, hmac, sha256), then a full 20,000-event block (the event limit)
  of small JSON bodies over 12 flaky endpoints, then 5,000 more commands. It
  measures the scheduler: ~43,000 deliveries and ~63,000 attempts through the
  priority queue, plus line parsing and output formatting at volume (9 MB out).
  The block stays within every limit in SPEC.md §4.1.

## Long tier

`python3 gen_bench.py --long` writes `../bench-long/` (same names). All three
expected outputs come from the reference.
No SPEC.md limit had to change.

- `001_gateway_sign_verify`: 1,200 gateway commands instead of 380 (same generator,
  30 MB). Its cost is hashing the payload bytes it carries, so it is bound by its own
  size: 5 s would need several hundred MB of hex payloads. It does **not** reach the
  5 s target (about 0.55 s for the fastest build). Expected output from the reference.
- `002_simulate_fanout`: 14 independent fan-out blocks instead of one (seeds 2002-2015;
  each block is a full 64-subscriber broadcast of 150 real GitHub events, about 80k
  deliveries and 145k attempts in total), 51 MB in, 24 MB out. The reference takes
  about 1.5 hours here (5,260 s user, 5,843 s wall, 179 MB peak RSS on a loaded
  machine); the C++, Rust, Go and D builds reproduce its output byte for byte.
- `003_dispatcher_mixed`: three dispatcher sessions (seeds 3003-3005), each the full
  5,000 API commands + 20,000-event retry storm + 5,000 commands. Every attempt is
  printed, so this one is bound by its output (23 MB here for 0.25 s); it does **not**
  reach the 5 s target. Expected output from the reference.

Measured on a heavily shared machine; times are CPU seconds normalised by a calibration
run to a lightly loaded machine: 001 C++ 0.55 s, 002 C++ 7.9 s (Go 8.4, Rust 8.6,
D 9.7), 003 C++ 0.25 s. Peak RSS at most 182 MB (D). Size on disk 142 MB.
