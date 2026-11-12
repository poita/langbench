// Package toml is a TOML 1.0.0 parser and canonical serializer.
//
// [Parse] reads a document into a tree of [*Table], [*Array] and [*Value]
// nodes. Scalars are kept as canonical text (see [Value]), so nothing is
// lost by converting dates or numbers to native Go types. [Encode] writes a
// tree back out as a canonical TOML document, and the subpackage tagged
// converts trees to and from the tagged JSON format used by the toml-test
// suite.
//
// The parser is strict: every rule of the TOML 1.0.0 grammar and of its
// table-definition semantics is enforced, and any violation is reported as a
// [*SyntaxError].
package toml
