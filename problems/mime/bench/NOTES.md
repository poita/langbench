# mime performance benchmark

Regenerate with `python3 problems/mime/bench/gen_bench.py` (fixed seeds; expected
outputs come from `reference/main.py`). Run with
`python3 run_tests.py mime --tests-dir problems/mime/bench -- <impl>/run.sh`.

- **001_mailing_list_mbox**: a 4.9 MB mbox of 900 synthetic list posts. Most are
  plain text with quoted replies and code; some are multipart/alternative
  (text + QP HTML) and some carry patch/CSV attachments. They have Received chains,
  long References, and LF or CRLF line endings. It tests throughput on the
  everyday path: mbox splitting, header unfolding, charset decoding and body
  dumping.
- **002_attachments_eml_dir**: a directory of 140 `.eml` files (4.6 MB, about
  half CRLF), each a deep business-style MIME tree. Each has
  mixed/related/alternative parts, base64 images and documents, QP HTML,
  RFC 2231 and encoded-word filenames, forwarded message/rfc822 parts that have
  their own attachments, and occasional digests. It tests MIME tree building,
  boundary scanning, transfer decoding, Adler-32 and attachment writing.
- **003_header_heavy_mbox**: a 3.2 MB mbox of 420 messages with short bodies.
  The headers carry most of the cost: To/Cc/Bcc lists of up to about 200
  addresses, written as quoted, encoded-word, commented and group forms, plus
  RFC 2047 subjects in four charsets and many Date variants (comments, named
  zones, 2-digit years, a few invalid). It tests the address tokenizer and
  grammar, RFC 2047 decoding and date parsing, which have the most algorithm
  work per byte.

Every message is at most 88 kB, and nesting, part and message counts are far
below the spec's limits. The inputs are larger than the test suite's largest
3.5 MB mbox, which SPEC.md gives only as a description of the test suite.
Bodies never start a line with `From ` right after an empty line, because that
case splits the mbox. The reference also treats a CRLF blank line before
`From ` differently from SPEC.md; see below.

Spec divergence found while building this: the reference's `split_mbox` treats
a CRLF blank line (`\r`) as non-empty, so `From ` after `\r\n\r\n` is not a
separator. SPEC.md says the line is empty, so it is a separator. The six C++/Rust/Go
builds checked (impls/ and runs/rep1/) all follow the spec. The benchmark avoids this case.

## Long tier

`python3 problems/mime/bench/gen_bench.py --long` writes `bench-long/`: the same three inputs with three times as many messages from new seeds (2700 list posts in a 15.0 MB mbox, 420 `.eml` files totalling 14.7 MB, 1260 header-heavy messages in a 9.8 MB mbox). Expected outputs come from `reference/main.py` (28 s in total). No SPEC.md limit applies.

**This tier does not reach the 5 s target.** The fastest builds need only 0.06-0.25 s CPU per input; their 0.4-1 s of wall time is mostly spent writing the output tree. Run time is linear in the input, and reaching 6 s would take inputs of well over 1 GB per case, so the tier is kept as a 3x-larger best-effort tier within the disk budget (`bench-long/` is 96 MB). Fastest wall times on the loaded machine: Go 0.50 s on 001, Go 0.38 s on 002, Go 0.59 s on 003. All five builds pass; the Python build takes 4-5 s and under 50 MB.
