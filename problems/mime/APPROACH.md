# mime: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `T` is the total input size (at most 3.5 MB), `N` one message's length,
`d ≤ 20` its nesting depth, `L` the length of one header field value.

## Algorithm

The mailbox is split into messages in one forward scan (or the directory's
`.eml` files are sorted by name). Each message has its line endings normalised,
then a recursive-descent parser builds the MIME part tree, numbering parts in
pre-order: a multipart body is scanned for delimiter lines, and each child,
the range between two delimiters, is parsed recursively. Each leaf's transfer
encoding and charset are decoded once. Header field values are decoded by
single-pass scanners: encoded words, structured values with RFC 2231
parameter assembly, address lists and dates.

## Required rules

1. **Each nesting level scans only its own body**, and a part's headers are
   found without scanning its body, so the part tree costs O(N·d).
2. **Each header field value is tokenised once**, O(L): address-list elements,
   phrases and parameters come from one token sequence.
3. **Dates are computed in closed form** with `days_from_civil` and its
   inverse, O(1) per date: no iteration over years or days.

## Complexity

The run is O(T) to split the input plus O(N·d) per message for the part tree.
Line-ending normalisation, transfer decoding, charset decoding and the Adler-32
checksum are linear in the text they cover; each header field value is O(L)
plus its decoded output, apart from a small sort of RFC 2231 segments per
parameter. Writing the output is linear in its size.
