// Package toml is a from-scratch TOML 1.0.0 parser and serializer.
//
// It has two halves:
//
//   - Decoding: [Parse] reads a TOML document into a tree of [*Table],
//     [*Array] and [*Value] nodes. Scalars are kept in a canonical textual
//     form (see [Value]), so the tree can be printed as "tagged JSON" — the
//     interchange format of the toml-test suite — with [Table.TaggedJSON].
//   - Encoding: [ParseTaggedJSON] reads tagged JSON back into the same kind
//     of tree and [Table.TOML] renders it as a canonical TOML document.
//
// The two directions round-trip: decoding the output of encoding a tree
// yields the same tree.
//
// The package depends only on the Go standard library and does not use any
// TOML implementation.
package toml
