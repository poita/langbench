# webhooks: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `L` is the input size, `B` a message length in bytes, `S` the number of
secrets in a command or endpoint, `T` the number of header tokens, `E`, `P` and
`D` the events, endpoints and deliveries of a `simulate` block and `A` its
attempts (`A ≤ 8D`).

## Algorithm

The input is read once, line by line, each field validated in one pass.
SHA-256, HMAC-SHA-256 and Base64 are the standard algorithms of SPEC.md §1.

A `simulate` block is read and validated in full before anything is computed.
After a valid `end` the deliveries are created in SPEC.md §4.2 order, each with
its signature header, and the simulation is driven by a min-priority queue of
`(scheduled time, delivery number)` pairs.

## Required rules

1. **`verify` computes one MAC per secret**, compared against every `v1` token:
   O(S·(B + T)), not O(S·T·B).
2. **Each delivery is signed once**, after its block's valid `end`, not once
   per attempt.
3. **Scheduling is O(log D) per operation**, for example with a binary heap
   holding at most one pending attempt per delivery. No sorting or scanning of
   all pending attempts per step.

## Complexity

Reading and validation are O(L). Hashing is O(B); `sign` is O(S·B) and `verify`
O(S·(B + T)). A block is O(E·P) to match events to endpoints,
O(Σ S·B) over its deliveries to sign, and O((D + A) log D) to simulate.
