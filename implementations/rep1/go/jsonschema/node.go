package jsonschema

import (
	"example.com/jsonschema/jsonvalue"
	"example.com/jsonschema/regex"
)

// Bits of node.typeMask.
const (
	tNull uint8 = 1 << iota
	tBoolean
	tObject
	tArray
	tNumber
	tString
	tInteger

	// tNone marks a type keyword that names no known type: nothing matches.
	tNone uint8 = 0x80
)

// count is an optional non-negative integer keyword value.
type count struct {
	set bool
	v   int64
}

// pattern is a compiled regular expression, or the error that prevented it.
type pattern struct {
	re  *regex.Regexp
	err error
}

type patternProp struct {
	pat   *pattern
	child *node
}

type depRequired struct {
	name  string
	names []string
}

type depSchema struct {
	name  string
	child *node
}

// node is one compiled schema (a boolean or an object). It records only the
// keywords that are present, already decoded into evaluation-ready form.
type node struct {
	isBool  bool
	boolVal bool
	base    int // interned base URI

	typeMask uint8
	enum     []jsonvalue.Value
	hasEnum  bool
	constVal *jsonvalue.Value

	multipleOf, maximum, minimum, exclusiveMax, exclusiveMin *jsonvalue.Number

	maxLength, minLength         count
	maxItems, minItems           count
	maxProperties, minProperties count
	maxContains, minContains     count
	pattern                      *pattern
	uniqueItems                  bool
	required                     []string
	dependentRequired            []depRequired

	prefixItems []*node
	items       *node
	contains    *node

	properties           map[string]*node
	patternProperties    []patternProp
	additionalProperties *node
	propertyNames        *node
	dependentSchemas     []depSchema

	allOf, anyOf, oneOf []*node
	not                 *node
	ifNode              *node
	thenNode, elseNode  *node

	unevaluatedItems      *node
	unevaluatedProperties *node
	hasUneval             bool

	// References, filled in by the resolution pass.
	hasRef    bool
	ref       *node
	refStr    string
	refErr    error
	hasDynRef bool
	dynRef    *node
	dynRefStr string
	dynRefErr error
	dynName   int // interned anchor name when the $dynamicRef is dynamic, else -1
}
