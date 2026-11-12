package jsonschema

import (
	"example.com/jsonschema/jsonvalue"
	"example.com/jsonschema/regex"
)

// Bits of node.types, one per type name accepted by the "type" keyword.
const (
	tNull uint8 = 1 << iota
	tBoolean
	tObject
	tArray
	tNumber
	tString
	tInteger
)

// node is a compiled schema object (or boolean schema). All keyword values are
// decoded once at compile time; nodes are immutable afterwards, so a compiled
// Schema can be used from many goroutines at once.
type node struct {
	isBool  bool // boolean schema; boolVal is its verdict
	boolVal bool

	base int32 // base URI id, used for the dynamic scope

	// Any type.
	types    uint8 // 0: no "type" keyword
	hasEnum  bool
	enum     []jsonvalue.Value
	hasConst bool
	constVal jsonvalue.Value

	// Numbers.
	multipleOf *jsonvalue.Number
	maximum    *jsonvalue.Number
	minimum    *jsonvalue.Number
	exMaximum  *jsonvalue.Number
	exMinimum  *jsonvalue.Number

	// Strings; length bounds are -1 when absent.
	maxLength int
	minLength int
	pattern   *regex.Regexp

	// Arrays.
	maxItems    int
	minItems    int
	uniqueItems bool
	prefixItems []*node
	items       *node
	contains    *node
	minContains int // default 1
	maxContains int // -1 when absent

	// Objects.
	maxProperties int
	minProperties int
	required      []string
	depRequired   []depRequired
	props         map[string]*node
	propList      []namedNode
	patProps      []patternProp
	additional    *node
	propertyNames *node
	depSchemas    []namedNode

	// In-place applicators.
	allOf, anyOf, oneOf []*node
	not                 *node
	ifNode              *node
	thenNode, elseNode  *node
	unevalItems         *node
	unevalProps         *node

	ref    *ref
	dynRef *ref
}

type namedNode struct {
	name string
	node *node
}

type patternProp struct {
	re   *regex.Regexp
	node *node
}

type depRequired struct {
	name  string
	names []string
}

// ref is a compiled $ref or $dynamicRef.
type ref struct {
	text    string // the reference as written, for diagnostics
	target  *node  // static target; nil if it could not be resolved
	err     string // why it could not be resolved
	dynamic bool   // $dynamicRef whose fragment names a dynamic anchor
	name    string // the anchor name when dynamic
}

var (
	trueNode  = &node{isBool: true, boolVal: true}
	falseNode = &node{isBool: true, boolVal: false}
)
