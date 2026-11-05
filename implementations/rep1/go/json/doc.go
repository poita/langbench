// Package jsoncanon parses strict JSON (RFC 8259) and serializes it in a
// canonical form.
//
// The parser is hand written and byte oriented. It accepts exactly the
// grammar of RFC 8259 with these additional rules: the input must be strictly
// valid UTF-8 without a byte-order mark, escaped surrogates must form proper
// pairs, and nesting is limited to [MaxDepth] levels. Numbers are never
// converted to floating point; they are kept as text, so integers of any size
// and any number of digits are preserved.
//
// The canonical form has no insignificant whitespace, sorts object members by
// the UTF-16 code unit order of their keys, keeps only the last of any
// duplicated keys, escapes only what JSON requires, and normalizes number
// exponents (see [Canonicalize]).
//
// Most callers only need [Canonicalize]. [Parse] exposes the value tree for
// callers that want to inspect a document before serializing it.
package jsoncanon
