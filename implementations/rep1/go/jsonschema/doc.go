// Package jsonschema validates JSON instances against JSON Schema draft
// 2020-12 schemas.
//
// It is built from scratch on the standard library only: the JSON parser
// (package jsonvalue), the regular-expression engine (package regex), the RFC
// 3986 URI machinery (package uri) and the RFC 6901 JSON Pointer evaluator
// (package jsonpointer) are all part of this module.
//
// # Model
//
// A Compiler turns a schema document, plus any number of additional "remote"
// documents registered by absolute URI, into an immutable Schema. Compilation
// walks every document once, builds a tree of typed nodes holding only the
// keywords that are present, indexes $id, $anchor and $dynamicAnchor, and
// pre-resolves every $ref and $dynamicRef. A Schema can then validate any
// number of instances, concurrently.
//
// # Semantics
//
// Numbers are exact decimals (never floats), so multipleOf and every bound
// comparison are exact. Strings are measured in code points. format, the
// content* keywords, $vocabulary and unknown keywords are annotations only
// and never reject. unevaluatedItems and unevaluatedProperties see the
// annotations produced by $ref, $dynamicRef, allOf, anyOf, oneOf,
// if/then/else, dependentSchemas, contains, properties and friends exactly as
// described by the specification: annotations of rejected branches never
// escape.
//
// # Errors
//
// Validate reports whether the instance is valid. It returns an error only
// when evaluation reaches something that cannot be evaluated: a reference
// that does not resolve, an invalid regular expression, or runaway recursion
// (for example a schema that refers to itself with no progress).
package jsonschema
