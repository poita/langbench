// Package toml is a from-scratch implementation of TOML 1.0.0: a strict parser,
// a canonical serializer, and the "tagged JSON" interchange format used by the
// toml-test suite.
//
// The package works on a single tree type, [Node]. [Parse] reads a TOML
// document into a tree, [MarshalTaggedJSON] and [ParseTaggedJSON] convert the
// tree to and from tagged JSON, and [MarshalTOML] renders a tree as canonical
// TOML text:
//
//	root, err := toml.Parse([]byte(`name = "Tom"`))
//	if err != nil { ... }
//	fmt.Println(root.Get("name").Text()) // Tom
//
// Scalars keep their canonical text form (see [Node.Text]); typed accessors
// such as [Node.Int64] and [Node.Float64] convert on demand. Date-times are
// handled textually, with no calendar arithmetic or time-zone conversion.
//
// The code is organised by responsibility:
//
//	node.go     the Node tree and its accessors
//	parser.go   statement-level parsing and table resolution
//	strings.go  the four string syntaxes and key scanning
//	scalar.go   integers, floats, booleans and date-times
//	tagged.go   tagged JSON writer and reader
//	encode.go   canonical TOML writer
//	errors.go   the Error type
package toml
