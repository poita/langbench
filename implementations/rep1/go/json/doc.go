// Package jsoncanon parses JSON documents (RFC 8259) strictly and serializes
// them in a canonical form.
//
// The parser and serializer are implemented from scratch, without
// encoding/json. Numbers are never converted to floating point: they are kept
// as text, so integers of any size and any number of fraction or exponent
// digits round-trip exactly.
//
// The canonical form has no insignificant whitespace, escapes only what must
// be escaped, normalizes exponents, removes duplicate object keys (the last
// occurrence wins) and orders object members by the UTF-16 code units of their
// keys.
//
// The typical entry point is [Canonicalize]:
//
//	out, err := jsoncanon.Canonicalize([]byte(`{"b":1,"a":[1E+2]}`))
//	// out == `{"a":[1e2],"b":1}`
//
// For finer control use [Parse] to obtain a [Value] tree and
// [Value.AppendCanonical] to serialize it.
package jsoncanon
