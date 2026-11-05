// Package toml is a from-scratch TOML 1.0.0 parser and serializer.
//
// It reads a TOML document into a tree of [Node] values (Parse), writes such a
// tree as "tagged JSON" (the interchange format of the toml-test suite;
// Node.AppendJSON), reads tagged JSON back into a tree (ParseJSON), and renders
// a tree as canonical TOML (Node.AppendTOML).
//
// Scalars are kept in canonical text form: integers in decimal, floats as
// 17-significant-digit scientific notation (or inf, -inf, nan), date-times in
// the normalised textual form described in the README. No calendar arithmetic
// or time-zone conversion is performed, so nothing is lost on the way through.
//
// The package depends only on the Go standard library and does not use any
// TOML implementation.
package toml
