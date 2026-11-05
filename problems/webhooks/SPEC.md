# webhooks — Standard Webhooks library with delivery simulator

Build a small cryptography and webhook-delivery library and drive it from a
command stream on stdin. You implement SHA-256, HMAC-SHA-256 and Base64 from
scratch, then the [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
signature scheme on top of them, then a deterministic delivery simulator that
signs events and retries failed deliveries on a fixed schedule.

Write SHA-256, HMAC and Base64 yourself: don't use a hash, MAC or Base64
routine from a library, the standard library or the language. Everything in
"Primitives" below is written out in full so it can be implemented from this
document alone.

All input is UTF-8 text with LF line endings. All output is UTF-8 text with LF
line endings. The program reads the whole of stdin and writes to stdout. The
exit code is always 0: every malformed input is a normal result whose output is
the single word `error`, never a crash. stderr is ignored.

A single input line can be long: the tests contain lines of about 64 KiB, so do
not read stdin into a small fixed-size line buffer. Every integer in this
document fits in a signed 64-bit integer, and so does every value computed from
one (timestamps are bounded by 10^15, the largest retry offset is 99305, and
differences of two timestamps are bounded by 2 x 10^15).

Expect roughly 1200–2000 lines in a systems language: ~250 for the primitives,
~350 for parsing and the signature scheme, ~400 for the simulator, the rest
structure and validation.

---

## 1. Primitives

### 1.1 SHA-256

FIPS 180-4 SHA-256 over a byte string of any length, producing 32 bytes.

Initial state `H[0..7]`:

```
6a09e667 bb67ae85 3c6ef372 a54ff53a 510e527f 9b05688c 1f83d9ab 5be0cd19
```

Round constants `K[0..63]`:

```
428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5
d807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174
e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da
983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967
27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85
a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070
19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3
748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2
```

Padding: append the byte `0x80`, then the fewest `0x00` bytes that make the
length ≡ 56 (mod 64), then the bit length of the original message as a 64-bit
big-endian integer.

For each 64-byte block, build `W[0..63]` of 32-bit words: `W[t]` for `t < 16` is
the `t`-th big-endian word of the block, and for `16 ≤ t < 64`

```
s0   = ror(W[t-15],7) xor ror(W[t-15],18) xor (W[t-15] >> 3)
s1   = ror(W[t-2],17) xor ror(W[t-2],19)  xor (W[t-2] >> 10)
W[t] = W[t-16] + s0 + W[t-7] + s1
```

with `ror` a 32-bit rotate right, `>>` a logical shift, and all additions modulo
2³². Then with `a..h` initialised from `H[0..7]`, for `t = 0..63`:

```
S1    = ror(e,6) xor ror(e,11) xor ror(e,25)
ch    = (e and f) xor ((not e) and g)
temp1 = h + S1 + ch + K[t] + W[t]
S0    = ror(a,2) xor ror(a,13) xor ror(a,22)
maj   = (a and b) xor (a and c) xor (b and c)
temp2 = S0 + maj
h = g; g = f; f = e; e = d + temp1
d = c; c = b; b = a; a = temp1 + temp2
```

After the loop add `a..h` into `H[0..7]` modulo 2³². The digest is `H[0..7]`
serialised big-endian, 32 bytes.

Test: `SHA-256("")` is
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
`SHA-256("abc")` is
`ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.

### 1.2 HMAC-SHA-256

RFC 2104 with block size 64 and SHA-256.

```
if len(key) > 64: key = SHA256(key)
key = key padded on the right with 0x00 to 64 bytes
ipad = key xor 0x36 repeated 64 times
opad = key xor 0x5c repeated 64 times
HMAC(key, msg) = SHA256(opad || SHA256(ipad || msg))
```

A zero-length key is legal (it pads to 64 zero bytes). The result is 32 bytes.

Test: `HMAC(key = 0x0b × 20, msg = "Hi There")` is
`b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7`
(RFC 4231 test case 1).

### 1.3 Base64

Two alphabets, both indexed 0..63:

```
standard: ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
url-safe: ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_
```

**Encoding.** Take the input three bytes at a time; the 24 bits become four
6-bit groups, most significant first, each mapped through the alphabet. A final
group of two bytes produces three characters, a final group of one byte produces
two characters. *Standard* encoding then appends `=` characters until the length
is a multiple of four (one `=` after three characters, two after two).
*URL-safe* encoding appends no padding.

**Decoding** (one routine, used for secrets, for signature values and for the
`b64dec` command). The input is a string of ASCII characters:

1. Split off the trailing run of `=` characters. Let *body* be what remains and
   *p* the number of `=`. An `=` anywhere else makes the string **invalid**.
2. Every character of *body* must belong to the standard alphabet or to the
   URL-safe alphabet. If *body* contains a character from `+/` **and** a
   character from `-_`, the string is **invalid** (alphabets must not be mixed).
   Any other character (including whitespace and newlines) makes the string
   **invalid**.
3. Let `n = len(body)`. If `n mod 4 == 1` the string is **invalid**.
4. If `p > 0` then `n + p` must be a multiple of 4 **and** `p` must be `1` when
   `n mod 4 == 3`, `2` when `n mod 4 == 2`, and the string is **invalid** when
   `n mod 4 == 0` (there is nothing to pad) — i.e. padding, when present, must
   be exactly the padding the encoder would have emitted. `p > 2` is always
   **invalid**.
5. Decode *body* by concatenating the 6-bit values of its characters into a bit
   string and taking the leading `floor(n * 6 / 8)` bytes. The `n * 6 mod 8`
   left-over low bits are discarded **without being checked**: `QQ==` and `QR==`
   both decode to the single byte `0x41`.

An empty string is valid and decodes to zero bytes.

Examples of the two encodings as functions (the `b64enc` and `b64urlenc`
*commands* print `-` instead of an empty string, see §3.2):

| input | standard | URL-safe |
|---|---|---|
| (empty) | (empty) | (empty) |
| `f` | `Zg==` | `Zg` |
| `fo` | `Zm8=` | `Zm8` |
| `foo` | `Zm9v` | `Zm9v` |
| bytes `fb ff` | `+/8=` | `-_8` |

---

## 2. Signature scheme

### 2.1 Secrets

A **secret** is a string. If it starts with the six characters `whsec_` that
prefix is removed, **once**: a second `whsec_` is part of what follows and is
Base64-decoded with it. What remains is Base64-decoded by the rule in §1.3 to
give the raw HMAC key. A secret whose remainder is not valid Base64, or which
decodes to zero bytes, is invalid.

`whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw` and
`MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw` are the same 24-byte key. Base64 padding is
optional, so `whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr` (25 bytes) is also a
valid secret.

### 2.2 Signing

Given a secret, a message id `id`, a timestamp `ts` (decimal, exactly as it
appears in the input) and a payload byte string `body`, the signed content is
the byte string

```
utf8(id) || "." || ascii(ts) || "." || body
```

and the signature is `"v1," || base64_standard(HMAC_SHA256(key, content))`,
where `base64_standard` is the padded standard encoding of §1.3. The HMAC is
always 32 bytes, so the Base64 is always 44 characters ending in `=`.

Worked example (the published Standard Webhooks test vector):

```
secret = whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw
id     = msg_p5jXN8AQM9LWM0D4loKWxJek
ts     = 1614265330
body   = {"test": 2432232314}
```

The signed content is
`msg_p5jXN8AQM9LWM0D4loKWxJek.1614265330.{"test": 2432232314}` and the
signature is `v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=`.

When several secrets are active (key rotation) the `webhook-signature` header
carries one signature per secret, in secret order, joined by single spaces:

```
v1,<sig with secret 0> v1,<sig with secret 1>
```

### 2.3 Verification

A verifier is given: the active secrets (in order), the received `webhook-id`,
the received `webhook-timestamp`, the received `webhook-signature` header value,
the body, and the current time `now` as a Unix timestamp in seconds. It performs
these steps **in this order** and stops at the first that decides:

1. Split the header on single space characters `0x20`. If every resulting
   token is empty (in particular, if the header is empty), verification fails
   with `missing-signature`.
2. If the timestamp is not a **canonical decimal integer** — `0`, or a non-zero
   run of digits with no leading zero, optionally preceded by `-`, with absolute
   value at most 10¹⁵ — verification fails with `invalid-timestamp`.
3. If `now - ts > 300` verification fails with `timestamp-too-old`. If
   `ts - now > 300` it fails with `timestamp-too-new`. The tolerance is
   inclusive: a difference of exactly 300 seconds in either direction passes.
4. For each secret *i* in order, and within that for each header token *j* in
   order (index *j* counts **all** tokens produced by the split in step 1,
   including empty ones), the token matches when all of the following hold:
   - the token contains at least one `,`; let *version* be the text before the
     first `,` and *value* the text after it;
   - *version* is exactly `v1`;
   - *value* is valid Base64 by §1.3;
   - the decoded bytes equal `HMAC_SHA256(key_i, content)` byte for byte, with
     `content` as in §2.2 using the received `id`, the received timestamp text
     and the body.

   The first matching `(i, j)` is the result. Tokens that do not match are
   skipped, never fatal: a header of `garbage v1,<good>` verifies.
5. If nothing matched, verification fails with `no-match`.

---

## 3. Input

Stdin is a sequence of lines. A line that is empty or consists only of spaces is
ignored and produces no output. Every other line is a command (or, inside a
`simulate` block, a block line). The last line may or may not end with `\n`.

Every grammar in this document is ASCII-only, so reading stdin as bytes and
reading it as text give the same answers; all field matching is bytewise, and
the character counts below are byte counts.

A command line is split into **fields** on single space characters `0x20`. Two
adjacent spaces, a leading space or a trailing space produce an empty field,
which always makes the line `error`. Tab and other whitespace characters are
not separators; they are ordinary characters inside a field and will fail the
field's own validation. A line whose first field is not one of the command names
below, or which has the wrong number of fields, produces `error`.

### 3.1 Argument kinds

**`<hex>`** — a byte string, written as an even number of lowercase hex digits
`0-9a-f`, or the single character `-` for the empty byte string. Uppercase hex
digits, an odd digit count, or any other character make the line `error`. The
empty byte string is *always* written `-`; a field is never zero-length.

**`<text-hex>`** — a hex-encoded UTF-8 *text* argument, same encoding as
`<hex>`. Free-form text (payload bodies, the received signature header, the
string handed to `b64dec`) is hex-encoded so that it may be empty, contain
spaces, or contain bytes that are not valid UTF-8.

**`<secret>`** — one secret (§2.1): 1..512 characters from `0x21`..`0x7e`,
excluding `,`. Any other length or character, or a secret that §2.1 calls
invalid, makes the line `error`.

**`<secrets>`** — one or more `<secret>` joined by commas `,`, at most 16. An
empty entry, a 17th entry, or an invalid entry makes the line `error`.

**`<id>`** — 1..256 characters from `0x21`..`0x7e` (printable ASCII, no space).
`-` is **not** special here: it is the one-character id `-`.

**`<int>`** — a canonical decimal integer as defined in §2.3 step 2: `0`, or an
optional `-` followed by a digit `1`-`9` and any number of digits, with absolute
value at most 10¹⁵. `+5`, `007`, `1.0`, `1e3` and `-0` are not canonical.

### 3.2 Commands

| command | fields | output |
|---|---|---|
| `sha256 <hex>` | 2 | 64 lowercase hex digits |
| `hmac <key-hex> <msg-hex>` | 3 | 64 lowercase hex digits |
| `b64enc <hex>` | 2 | padded standard Base64, or `-` if empty |
| `b64urlenc <hex>` | 2 | unpadded URL-safe Base64, or `-` if empty |
| `b64dec <text-hex>` | 2 | lowercase hex of the decoded bytes, `-` if empty, `error` if the text is not valid Base64 |
| `secret <secret>` | 2 | lowercase hex of the raw key, or `error` |
| `sign <secrets> <id> <ts> <payload-hex>` | 5 | the `webhook-signature` header value |
| `verify <secrets> <id> <ts> <now> <header-hex> <payload-hex>` | 7 | `ok <i> <j>` or `fail <reason>` |
| `simulate` | 1 | a block, see §4 |

Notes:

- Wherever an output would be an empty hex or Base64 string, the single
  character `-` is printed instead, so no command ever prints an empty line.
- `sign`: `<ts>` must be an `<int>`; otherwise the line is `error`. Any invalid
  secret makes the line `error`. The output is one `v1,<base64>` per secret in
  order, joined by single spaces.
- `verify`: `<ts>` is **not** required to be canonical — it is data received
  from the network, so a non-canonical value yields `fail invalid-timestamp`
  rather than `error`. It must still be a field of 1..64 characters from
  `0x21`..`0x7e`, or the line is `error`. `<now>` is the harness clock and must
  be an `<int>`, else `error`. An invalid secret makes the line `error`.
- `verify` success prints `ok <i> <j>` with the 0-based secret index and the
  0-based header-token index from §2.3 step 4. Failure prints `fail ` followed
  by one of `missing-signature`, `invalid-timestamp`, `timestamp-too-old`,
  `timestamp-too-new`, `no-match`.

### 3.3 Worked examples

Input (`P` below stands for the hex of `{"test": 2432232314}`, i.e.
`7b2274657374223a20323433323233323331347d`, and `H` for the hex of
`v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=`, i.e.
`76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d`):

```
sha256 -
sha256 616263
hmac - -
b64enc 666f6f
b64urlenc fbff
b64dec 5a6d3976
b64dec -
secret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw
sign whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 P
verify whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 1614265400 H P
verify whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 1614265631 H P
verify whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 1614265400 H 7b7d
verify whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330 1614265400 - P
sha256 ABCD
sha256 abc
frobnicate 1
```

Output:

```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad
Zm9v
-_8
666f6f
-
31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0
v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=
ok 0 0
fail timestamp-too-old
fail no-match
fail missing-signature
error
error
error
```

Line by line: `b64dec -` decodes the empty string to the empty byte string, so it
prints `-`. `31f290...` is the 24-byte key the secret decodes to. `now` of
1614265631 is 301 seconds after the timestamp, one past the tolerance. The
fourth `verify` changes the body to `{}`, so nothing matches; the fifth sends an
empty header. `sha256 ABCD` has uppercase hex digits, `sha256 abc` has an odd
number of digits, and `frobnicate` is not a command.

---

## 4. The delivery simulator

### 4.1 Block syntax

The command `simulate` introduces a block. The line must be exactly `simulate`
with no further fields; a line such as `simulate now` is simply an `error`
command line and does **not** open a block, so the lines after it are read as
ordinary commands (and a stray `end`, `endpoint` or `event` line is an unknown
command, hence `error`). The
lines that follow are, in order:

```
endpoint <ep-id> <secrets> <filter> <script>
...
event <ev-id> <ts> <type> <payload-hex>
...
end
```

- All `endpoint` lines come first, then all `event` lines, then a line that is
  exactly `end`.
- `<ep-id>` and `<ev-id>` are 1..64 characters from `[A-Za-z0-9_.-]`, unique
  among endpoints and among events respectively. There are 1..64 endpoints and
  0..20000 events: a 65th `endpoint` line or a 20001st `event` line violates the
  block, as does a block with no `endpoint` line at all.
- `<secrets>` is a `<secrets>` field as in §3.1: the endpoint's active keys, in
  order.
- `<filter>` is either the single character `*` (deliver every event) or a
  comma-separated list of 1..16 event types.
- `<type>` and each filter entry are 1..64 characters from `[A-Za-z0-9_.-]`.
  An event matches an endpoint when the filter is `*` or when the event's type
  equals one of the filter's entries exactly.
- `<script>` is a comma-separated list of 1..64 **responses**, each either a
  three-digit status code `100`..`599` or the word `timeout`.
- `<ts>` is an `<int>`: the moment the event is enqueued.
- `<payload-hex>` is a `<hex>` field: the request body.

If any line of the block violates the above (wrong field count, bad field,
duplicate id, an `endpoint` line after an `event` line, an unexpected command,
a `simulate` line inside the block), the whole block is an `error`: the reader
keeps consuming lines until a line that is exactly `end`, or until end of input,
then prints the single word `error` and carries on with the next command. If
end of input is reached before `end`, the block is likewise `error`.

Note that blank lines are ignored inside the block exactly as outside it.

### 4.2 Deliveries

For each event, in event declaration order, and for each endpoint that matches
it, in endpoint declaration order, create one **delivery**. Deliveries are
numbered from 0 in creation order; that number is the tie-break for scheduling.

A delivery's request headers are fixed when it is created and never change
across retries:

```
webhook-id:        <ev-id>
webhook-timestamp: <the event's ts, exactly as written in the input>
webhook-signature: <one v1 signature per endpoint secret, joined by spaces>
```

signed over the event's payload as in §2.2.

### 4.3 The retry schedule

A delivery makes at most **8 attempts**: the first at the event's `ts`, and up
to 7 retries. The delay from attempt *n* to attempt *n+1* is the *n*-th entry of

```
5s, 5m, 30m, 2h, 5h, 10h, 10h
```

i.e. in seconds `5, 300, 1800, 7200, 18000, 36000, 36000`. So the attempts of a
delivery enqueued at `t` land at

```
t, t+5, t+305, t+2105, t+9305, t+27305, t+63305, t+99305
```

### 4.4 Running the simulation

Maintain a set of **pending attempts**, each belonging to one delivery and
carrying a scheduled time. Initially it holds attempt 1 of every delivery.
Repeatedly remove the pending attempt with the smallest
`(scheduled time, delivery number)` — the pair is unique because a delivery has
at most one pending attempt at a time — and process it:

- If the attempt's endpoint has been **disabled**, the delivery finishes with
  status `disabled`. No attempt is recorded.
- Otherwise the attempt is made. Take the next response from the endpoint's
  script: each endpoint has a cursor that starts at the script's first entry and
  advances by one on every attempt made to that endpoint; once the cursor runs
  past the end, every further attempt uses the **last** entry of the script.
  Record an attempt line, then:
  - status code 200..299 → outcome `success`; the delivery finishes with status
    `delivered`.
  - status code 410 → outcome `gone`; the delivery finishes with status
    `failed`, and the endpoint becomes **disabled** from this moment on.
  - `timeout` → outcome `timeout`; retryable.
  - any other status code → outcome `failure`; retryable.

  For a retryable outcome: if this was attempt 8 the delivery finishes with
  status `failed`; otherwise attempt *n+1* is scheduled at this attempt's time
  plus the delay from §4.3 and becomes pending.

Because the queue is ordered by time, events do not have to be declared in
timestamp order; an event with an earlier `ts` is processed earlier.

### 4.5 Output

A well-formed block prints

```
sim <A> <D>
```

where `A` is the number of attempt lines and `D` the number of deliveries,
followed by `A` attempt lines in processing order and then `D` delivery lines in
delivery-number order.

```
attempt <seq> <ev-id> <ep-id> <n> <ts> <outcome> <code>
```

- `<seq>` — 1-based, counts attempt lines in this block.
- `<n>` — 1-based attempt number within the delivery.
- `<ts>` — the attempt's scheduled time, a decimal integer.
- `<outcome>` — `success`, `failure`, `timeout` or `gone`.
- `<code>` — the status code, or `-` for a `timeout`.

```
delivery <ev-id> <ep-id> <status> <attempts> <last-ts> <header>
```

- `<status>` — `delivered`, `failed` or `disabled`. A delivery can reach
  `disabled` after one or more attempts of its own: it retried, and the
  endpoint was disabled by some other delivery before the retry came round.
- `<attempts>` — how many attempts were made (0..8).
- `<last-ts>` — the scheduled time of the last attempt made, or `-` if none.
- `<header>` — the delivery's `webhook-signature` header value from §4.2. It
  contains spaces when the endpoint has several secrets, and is always the last
  thing on the line.

### 4.6 Worked example

Input:

```
simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200
event msg_1 1700000000 user.created 7b7d
event msg_2 1700000100 repo.pushed 7b7d
end
```

`msg_1` matches both endpoints; `msg_2` matches only `ep_a`. Deliveries are
numbered 0 = (msg_1, ep_a), 1 = (msg_1, ep_b), 2 = (msg_2, ep_a).

Delivery 0 attempts at 1700000000 (script entry `500` → failure), 1700000005
(`timeout`), 1700000305 (`200` → success). Delivery 1 attempts once at
1700000000 and succeeds. Delivery 2's first attempt is at 1700000100, which
falls between delivery 0's second and third attempts; `ep_a`'s cursor has
reached the end of the script, so it and every later attempt to `ep_a` use the
last entry `200`.

Output:

```
sim 5 3
attempt 1 msg_1 ep_a 1 1700000000 failure 500
attempt 2 msg_1 ep_b 1 1700000000 success 200
attempt 3 msg_1 ep_a 2 1700000005 timeout -
attempt 4 msg_2 ep_a 1 1700000100 success 200
attempt 5 msg_1 ep_a 3 1700000305 success 200
delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=
delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s=
delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U=
```

Note that `attempt 4` precedes `attempt 5` even though delivery 2 was created
after delivery 0: ordering is by scheduled time first.

---

## 5. Error summary

A line prints `error` when, and only when:

- it has an unknown first field, or the wrong number of fields for its command,
  or any empty field;
- a `<hex>` or `<text-hex>` field is not `-` and not an even-length run of
  lowercase hex digits;
- a `<secrets>` field has an empty entry, more than 16 entries, or an entry that
  is not a valid secret (§2.1), or a character outside `0x21`..`0x7e`;
- an `<id>`, `<int>`, `<ep-id>`, `<ev-id>`, `<type>`, `<filter>` or `<script>`
  field breaks its grammar above;
- the text handed to `b64dec` is not valid Base64;
- a `simulate` block is malformed as described in §4.1.

Everything else — an unsigned payload, a stale timestamp, a signature that does
not match, an endpoint that returns 500 forever — is a normal result reported in
the command's own output.
