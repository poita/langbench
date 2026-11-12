package jsonschema

import (
	"fmt"
	"math"

	"example.com/jsonschema/jsonpointer"
	"example.com/jsonschema/jsonvalue"
	"example.com/jsonschema/regex"
	"example.com/jsonschema/uri"
)

// resource is a schema resource: a schema object (or boolean) registered under
// a base URI.
type resource struct {
	value jsonvalue.Value
	node  *node
}

type anchorKey struct {
	base int32
	name string
}

// compilation is the state of one Compiler.Compile run: it indexes every
// document, decodes every schema object into a node, and then resolves all
// references.
type compilation struct {
	ids       map[string]int32
	resources map[string]*resource
	anchors   map[anchorKey]*node
	dynamic   map[anchorKey]*node
	byObject  map[*jsonvalue.Object]*node
	refs      []refSite
	err       error
}

// refSite is a reference awaiting resolution against the base it appeared under.
type refSite struct {
	r    *ref
	base string
	dyn  bool
}

func newCompilation() *compilation {
	return &compilation{
		ids:       map[string]int32{},
		resources: map[string]*resource{},
		anchors:   map[anchorKey]*node{},
		dynamic:   map[anchorKey]*node{},
		byObject:  map[*jsonvalue.Object]*node{},
	}
}

func (c *compilation) fail(err error) {
	if c.err == nil {
		c.err = err
	}
}

func (c *compilation) baseID(base string) int32 {
	id, ok := c.ids[base]
	if !ok {
		id = int32(len(c.ids))
		c.ids[base] = id
	}
	return id
}

// document indexes and compiles one document whose retrieval URI is retrieval.
func (c *compilation) document(retrieval string, doc jsonvalue.Value) *node {
	root := c.schema(doc, retrieval)
	if _, taken := c.resources[retrieval]; !taken {
		c.resources[retrieval] = &resource{value: doc, node: root}
	}
	return root
}

func isSchemaValue(v jsonvalue.Value) bool {
	k := v.Kind()
	return k == jsonvalue.Bool || k == jsonvalue.ObjectKind
}

// schema compiles the schema v appearing under the base URI base.
func (c *compilation) schema(v jsonvalue.Value, base string) *node {
	if b, ok := v.Bool(); ok {
		if b {
			return trueNode
		}
		return falseNode
	}
	o, ok := v.Object()
	if !ok {
		return trueNode // not a schema: ignored like an unknown keyword's value
	}
	n := &node{maxLength: -1, minLength: -1, maxItems: -1, minItems: -1,
		maxContains: -1, minContains: 1, maxProperties: -1, minProperties: -1}
	c.byObject[o] = n

	if idv, ok := o.Get("$id"); ok {
		if id, ok := idv.Str(); ok {
			base = uri.Resolve(uri.Parse(base), uri.Parse(id)).WithoutFragment().String()
			if _, taken := c.resources[base]; !taken {
				c.resources[base] = &resource{value: v, node: n}
			}
		}
	}
	bid := c.baseID(base)
	n.base = bid

	if s, ok := stringMember(o, "$anchor"); ok {
		if _, taken := c.anchors[anchorKey{bid, s}]; !taken {
			c.anchors[anchorKey{bid, s}] = n
		}
	}
	if s, ok := stringMember(o, "$dynamicAnchor"); ok {
		if _, taken := c.dynamic[anchorKey{bid, s}]; !taken {
			c.dynamic[anchorKey{bid, s}] = n
		}
	}

	c.anyType(n, o)
	c.numbers(n, o)
	c.strings(n, o)
	c.arrays(n, o, base)
	c.objects(n, o, base)
	c.applicators(n, o, base)

	if s, ok := stringMember(o, "$ref"); ok {
		n.ref = &ref{text: s}
		c.refs = append(c.refs, refSite{n.ref, base, false})
	}
	if s, ok := stringMember(o, "$dynamicRef"); ok {
		n.dynRef = &ref{text: s}
		c.refs = append(c.refs, refSite{n.dynRef, base, true})
	}

	// Subschema positions that are indexed but never applied.
	if d, ok := o.Get("$defs"); ok {
		c.schemaMap(d, base)
	}
	if d, ok := o.Get("contentSchema"); ok && isSchemaValue(d) {
		c.schema(d, base)
	}
	return n
}

func stringMember(o *jsonvalue.Object, key string) (string, bool) {
	v, ok := o.Get(key)
	if !ok {
		return "", false
	}
	return v.Str()
}

// sub compiles the schema-valued keyword key, or returns nil if it is absent
// or does not hold a schema.
func (c *compilation) sub(o *jsonvalue.Object, key, base string) *node {
	v, ok := o.Get(key)
	if !ok || !isSchemaValue(v) {
		return nil
	}
	return c.schema(v, base)
}

// schemaList compiles an array-of-schemas keyword.
func (c *compilation) schemaList(o *jsonvalue.Object, key, base string) []*node {
	v, ok := o.Get(key)
	if !ok {
		return nil
	}
	arr, ok := v.Array()
	if !ok {
		return nil
	}
	out := make([]*node, 0, len(arr))
	for _, e := range arr {
		if isSchemaValue(e) {
			out = append(out, c.schema(e, base))
		}
	}
	return out
}

// schemaMap compiles a name -> schema keyword value in document order.
func (c *compilation) schemaMap(v jsonvalue.Value, base string) []namedNode {
	m, ok := v.Object()
	if !ok {
		return nil
	}
	out := make([]namedNode, 0, m.Len())
	for i := 0; i < m.Len(); i++ {
		k, e := m.At(i)
		if isSchemaValue(e) {
			out = append(out, namedNode{k, c.schema(e, base)})
		}
	}
	return out
}

func (c *compilation) anyType(n *node, o *jsonvalue.Object) {
	if v, ok := o.Get("type"); ok {
		switch v.Kind() {
		case jsonvalue.String:
			s, _ := v.Str()
			n.types = typeBit(s)
			if n.types == 0 {
				n.types = 0x80 // a name matching nothing
			}
		case jsonvalue.Array:
			arr, _ := v.Array()
			for _, e := range arr {
				if s, ok := e.Str(); ok {
					n.types |= typeBit(s)
				}
			}
			if n.types == 0 {
				n.types = 0x80
			}
		}
	}
	if v, ok := o.Get("enum"); ok {
		if arr, ok := v.Array(); ok {
			n.hasEnum, n.enum = true, arr
		}
	}
	if v, ok := o.Get("const"); ok {
		n.hasConst, n.constVal = true, v
	}
}

func typeBit(s string) uint8 {
	switch s {
	case "null":
		return tNull
	case "boolean":
		return tBoolean
	case "object":
		return tObject
	case "array":
		return tArray
	case "number":
		return tNumber
	case "string":
		return tString
	case "integer":
		return tInteger
	}
	return 0
}

func numberMember(o *jsonvalue.Object, key string) *jsonvalue.Number {
	v, ok := o.Get(key)
	if !ok {
		return nil
	}
	num, ok := v.Number()
	if !ok {
		return nil
	}
	return &num
}

func (c *compilation) numbers(n *node, o *jsonvalue.Object) {
	n.multipleOf = numberMember(o, "multipleOf")
	if n.multipleOf != nil && n.multipleOf.Sign() <= 0 {
		n.multipleOf = nil // not a positive number: ignored
	}
	n.maximum = numberMember(o, "maximum")
	n.minimum = numberMember(o, "minimum")
	n.exMaximum = numberMember(o, "exclusiveMaximum")
	n.exMinimum = numberMember(o, "exclusiveMinimum")
}

// count decodes a non-negative integer keyword that may be written in any
// numeric form (2, 2.0, 2e0). It returns def when absent or malformed.
func count(o *jsonvalue.Object, key string, def int) int {
	num := numberMember(o, key)
	if num == nil || !num.IsInteger() || num.Sign() < 0 {
		return def
	}
	if i, ok := num.Int64(); ok && i < math.MaxInt32 {
		return int(i)
	}
	return math.MaxInt32
}

func (c *compilation) strings(n *node, o *jsonvalue.Object) {
	n.maxLength = count(o, "maxLength", -1)
	n.minLength = count(o, "minLength", -1)
	if s, ok := stringMember(o, "pattern"); ok {
		re, err := regex.Compile(s)
		if err != nil {
			c.fail(fmt.Errorf("jsonschema: pattern: %w", err))
			return
		}
		n.pattern = re
	}
}

func (c *compilation) arrays(n *node, o *jsonvalue.Object, base string) {
	n.maxItems = count(o, "maxItems", -1)
	n.minItems = count(o, "minItems", -1)
	if v, ok := o.Get("uniqueItems"); ok {
		n.uniqueItems, _ = v.Bool()
	}
	n.prefixItems = c.schemaList(o, "prefixItems", base)
	n.items = c.sub(o, "items", base)
	n.contains = c.sub(o, "contains", base)
	n.minContains = count(o, "minContains", 1)
	n.maxContains = count(o, "maxContains", -1)
}

func (c *compilation) objects(n *node, o *jsonvalue.Object, base string) {
	n.maxProperties = count(o, "maxProperties", -1)
	n.minProperties = count(o, "minProperties", -1)
	if v, ok := o.Get("required"); ok {
		n.required = stringList(v)
	}
	if v, ok := o.Get("dependentRequired"); ok {
		if m, ok := v.Object(); ok {
			for i := 0; i < m.Len(); i++ {
				k, e := m.At(i)
				n.depRequired = append(n.depRequired, depRequired{k, stringList(e)})
			}
		}
	}
	if v, ok := o.Get("properties"); ok {
		n.propList = c.schemaMap(v, base)
		n.props = make(map[string]*node, len(n.propList))
		for _, p := range n.propList {
			n.props[p.name] = p.node
		}
	}
	if v, ok := o.Get("patternProperties"); ok {
		for _, p := range c.schemaMap(v, base) {
			re, err := regex.Compile(p.name)
			if err != nil {
				c.fail(fmt.Errorf("jsonschema: patternProperties: %w", err))
				continue
			}
			n.patProps = append(n.patProps, patternProp{re, p.node})
		}
	}
	n.additional = c.sub(o, "additionalProperties", base)
	n.propertyNames = c.sub(o, "propertyNames", base)
	if v, ok := o.Get("dependentSchemas"); ok {
		n.depSchemas = c.schemaMap(v, base)
	}
}

func stringList(v jsonvalue.Value) []string {
	arr, ok := v.Array()
	if !ok {
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, e := range arr {
		if s, ok := e.Str(); ok {
			out = append(out, s)
		}
	}
	return out
}

func (c *compilation) applicators(n *node, o *jsonvalue.Object, base string) {
	n.allOf = c.schemaList(o, "allOf", base)
	n.anyOf = c.schemaList(o, "anyOf", base)
	n.oneOf = c.schemaList(o, "oneOf", base)
	n.not = c.sub(o, "not", base)
	n.ifNode = c.sub(o, "if", base)
	n.thenNode = c.sub(o, "then", base)
	n.elseNode = c.sub(o, "else", base)
	n.unevalItems = c.sub(o, "unevaluatedItems", base)
	n.unevalProps = c.sub(o, "unevaluatedProperties", base)
}

// resolveRefs resolves every recorded reference. Failures are stored in the
// reference rather than reported: a dangling reference only matters if
// validation actually reaches it.
func (c *compilation) resolveRefs() {
	for _, site := range c.refs {
		c.resolve(site)
	}
}

func (c *compilation) resolve(site refSite) {
	r := site.r
	full := uri.Resolve(uri.Parse(site.base), uri.Parse(r.text))
	frag := uri.PercentDecode(full.Fragment)
	docURI := full.WithoutFragment().String()

	res, ok := c.resources[docURI]
	if !ok {
		r.err = fmt.Sprintf("no schema registered for %q", docURI)
		return
	}
	switch {
	case frag == "":
		r.target = res.node
	case frag[0] == '/':
		target, err := jsonpointer.Eval(res.value, frag)
		if err != nil {
			r.err = fmt.Sprintf("pointer %q in %q: %v", frag, docURI, err)
			return
		}
		r.target = c.nodeFor(target, docURI)
		if r.target == nil {
			r.err = fmt.Sprintf("pointer %q in %q does not designate a schema", frag, docURI)
		}
	default:
		bid := c.baseID(docURI)
		t, ok := c.anchors[anchorKey{bid, frag}]
		if !ok {
			t, ok = c.dynamic[anchorKey{bid, frag}]
		}
		if !ok {
			r.err = fmt.Sprintf("no anchor %q in %q", frag, docURI)
			return
		}
		r.target = t
		if site.dyn {
			if _, isDyn := c.dynamic[anchorKey{bid, frag}]; isDyn {
				r.dynamic, r.name = true, frag
			}
		}
	}
}

// nodeFor finds the compiled node of the schema value v that a JSON Pointer
// landed on. A position the indexing walk did not visit (for example under an
// unknown keyword such as "definitions") is compiled on demand.
func (c *compilation) nodeFor(v jsonvalue.Value, base string) *node {
	if b, ok := v.Bool(); ok {
		if b {
			return trueNode
		}
		return falseNode
	}
	o, ok := v.Object()
	if !ok {
		return nil
	}
	if n, ok := c.byObject[o]; ok {
		return n
	}
	before := len(c.refs)
	n := c.schema(v, base)
	for _, site := range c.refs[before:] {
		c.resolve(site)
	}
	return n
}
