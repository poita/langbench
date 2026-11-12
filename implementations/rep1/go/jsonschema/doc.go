// Package jsonschema validates JSON instances against JSON Schema draft 2020-12.
//
// Everything is implemented from scratch on top of the standard library: the
// JSON parser and exact-decimal number model (package jsonvalue), the regular
// expression engine for "pattern" (package regex), RFC 3986 reference
// resolution (package uri) and RFC 6901 pointers (package jsonpointer).
//
// # Usage
//
//	schema, err := jsonschema.CompileJSON([]byte(`{"type":"integer","minimum":1}`))
//	if err != nil { ... }
//	ok, err := schema.ValidateJSON([]byte(`3`))
//
// Schemas that refer to other documents by absolute URI are compiled with a
// Compiler, which is given those documents up front:
//
//	var c jsonschema.Compiler
//	c.AddResource("http://example.com/integer.json", integerDoc)
//	schema, err := c.Compile(root)
//
// # Semantics
//
// The package validates with the standard 2020-12 vocabularies: core
// ($id, $ref, $anchor, $dynamicAnchor, $dynamicRef, $defs), applicator,
// unevaluated, validation. "format" is an annotation and never rejects;
// "$vocabulary" and "$schema" are ignored; the content keywords are inert.
// Numbers are exact decimals, so "multipleOf" and the bound keywords never
// suffer floating point error. Regular expressions follow ECMA-262 (see
// package regex).
//
// Validate answers only valid or invalid; it does not produce error
// descriptions.
package jsonschema
