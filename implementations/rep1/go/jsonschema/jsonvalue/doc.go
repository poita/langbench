// Package jsonvalue is a small JSON data model and parser with exact decimal
// numbers.
//
// Unlike encoding/json, numbers are never routed through binary floating
// point: a literal such as 0.0001 or 1e400 is kept as an exact
// mantissa/exponent pair (see Number), so comparison, integer tests and
// divisibility are exact. Objects keep their members in document order and
// offer constant-time key lookup for larger objects.
//
// The package also defines JSON equality (Equal) and a hash consistent with
// it (Hash), as used by JSON Schema's enum, const and uniqueItems.
package jsonvalue
