package jsonschema

import (
	"fmt"

	"example.com/jsonschema/jsonpointer"
	"example.com/jsonschema/jsonvalue"
	"example.com/jsonschema/regex"
	"example.com/jsonschema/uri"
)

// Compiler builds Schemas. Register remote documents with AddResource, then
// call Compile. A Compiler may be reused; each Compile call builds an
// independent, immutable Schema.
type Compiler struct {
	remotes []remoteDoc
}

type remoteDoc struct {
	uri string
	doc *jsonvalue.Value
}

// NewCompiler returns an empty Compiler.
func NewCompiler() *Compiler { return &Compiler{} }

// AddResource registers a schema document under an absolute retrieval URI so
// that references from other schemas can find it. Nothing is ever fetched
// over the network: documents that are not registered cannot be referenced.
func (c *Compiler) AddResource(uri string, doc jsonvalue.Value) {
	d := doc
	c.remotes = append(c.remotes, remoteDoc{uri: uri, doc: &d})
}

// Compile compiles doc, whose retrieval URI is the empty string, together
// with every registered resource.
//
// Compile fails only if doc is neither a boolean nor an object. Problems
// inside a schema that evaluation might never reach (unresolvable references,
// invalid patterns) are reported by Validate if and when they are hit.
func (c *Compiler) Compile(doc jsonvalue.Value) (*Schema, error) {
	if k := doc.Kind(); k != jsonvalue.KindObject && k != jsonvalue.KindBool {
		return nil, fmt.Errorf("jsonschema: a schema must be an object or a boolean, not %s", k)
	}
	b := &builder{
		ids:       map[string]int{},
		resources: map[string]*resource{},
		byValue:   map[*jsonvalue.Value]*node{},
		anchors:   map[anchorKey]*node{},
		dynamic:   map[anchorKey]*node{},
		patterns:  map[string]*pattern{},
	}
	root := new(jsonvalue.Value)
	*root = doc
	rootNode := b.document("", root)
	for _, r := range c.remotes {
		b.document(r.uri, r.doc)
	}
	b.resolveAll()
	return &Schema{root: rootNode, dynTargets: b.dynTargets()}, nil
}

type anchorKey struct {
	base int
	name int
}

type resource struct {
	node *node
	val  *jsonvalue.Value
}

type builder struct {
	strs      []string
	ids       map[string]int
	resources map[string]*resource
	byValue   map[*jsonvalue.Value]*node
	anchors   map[anchorKey]*node // $anchor
	dynamic   map[anchorKey]*node // $dynamicAnchor
	patterns  map[string]*pattern
	refNodes  []*node
}

func (b *builder) intern(s string) int {
	if id, ok := b.ids[s]; ok {
		return id
	}
	id := len(b.strs)
	b.strs = append(b.strs, s)
	b.ids[s] = id
	return id
}

// dynTargets maps every (base, name) dynamic anchor to the node a plain
// lookup finds (so that an $anchor of the same name wins).
func (b *builder) dynTargets() map[anchorKey]*node {
	out := make(map[anchorKey]*node, len(b.dynamic))
	for k, n := range b.dynamic {
		if a, ok := b.anchors[k]; ok {
			n = a
		}
		out[k] = n
	}
	return out
}

// document indexes and compiles one document under its retrieval URI.
func (b *builder) document(retrieval string, v *jsonvalue.Value) *node {
	n := b.walk(v, retrieval)
	if _, taken := b.resources[retrieval]; !taken {
		b.resources[retrieval] = &resource{node: n, val: v}
	}
	return n
}

func (b *builder) pattern(src string) *pattern {
	if p, ok := b.patterns[src]; ok {
		return p
	}
	re, err := regex.Compile(src)
	p := &pattern{re: re, err: err}
	b.patterns[src] = p
	return p
}

func countOf(v *jsonvalue.Value) count {
	if v.Kind() != jsonvalue.KindNumber {
		return count{}
	}
	return count{set: true, v: v.Number().Int64()}
}

func numberOf(v *jsonvalue.Value) *jsonvalue.Number {
	if v.Kind() != jsonvalue.KindNumber {
		return nil
	}
	n := v.Number()
	return &n
}

func typeBit(name string) uint8 {
	switch name {
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

// walk compiles the schema at v, whose enclosing base URI is base, and
// registers its identifiers.
func (b *builder) walk(v *jsonvalue.Value, base string) *node {
	n := &node{dynName: -1}
	b.byValue[v] = n
	switch v.Kind() {
	case jsonvalue.KindBool:
		n.isBool, n.boolVal = true, v.Bool()
		return n
	case jsonvalue.KindObject:
	default:
		return n // not a schema: accepts everything
	}
	obj := v.Object()

	if id := obj.Get("$id"); id != nil && id.Kind() == jsonvalue.KindString {
		base = uri.Resolve(base, uri.StripFragment(id.Str()))
		if _, taken := b.resources[base]; !taken {
			b.resources[base] = &resource{node: n, val: v}
		}
	}
	n.base = b.intern(base)
	if a := obj.Get("$anchor"); a != nil && a.Kind() == jsonvalue.KindString {
		k := anchorKey{n.base, b.intern(a.Str())}
		if _, taken := b.anchors[k]; !taken {
			b.anchors[k] = n
		}
	}
	if a := obj.Get("$dynamicAnchor"); a != nil && a.Kind() == jsonvalue.KindString {
		k := anchorKey{n.base, b.intern(a.Str())}
		if _, taken := b.dynamic[k]; !taken {
			b.dynamic[k] = n
		}
	}

	for i := range obj.Members() {
		m := &obj.Members()[i]
		val := &m.Value
		switch m.Key {
		case "type":
			switch val.Kind() {
			case jsonvalue.KindString:
				n.typeMask = typeBit(val.Str())
			case jsonvalue.KindArray:
				for _, t := range val.Array() {
					if t.Kind() == jsonvalue.KindString {
						n.typeMask |= typeBit(t.Str())
					}
				}
			}
			if n.typeMask == 0 && (val.Kind() == jsonvalue.KindString || val.Kind() == jsonvalue.KindArray) {
				n.typeMask = tNone // only unknown type names: matches nothing
			}
		case "enum":
			if val.Kind() == jsonvalue.KindArray {
				n.enum, n.hasEnum = val.Array(), true
			}
		case "const":
			n.constVal = val
		case "multipleOf":
			n.multipleOf = numberOf(val)
		case "maximum":
			n.maximum = numberOf(val)
		case "minimum":
			n.minimum = numberOf(val)
		case "exclusiveMaximum":
			n.exclusiveMax = numberOf(val)
		case "exclusiveMinimum":
			n.exclusiveMin = numberOf(val)
		case "maxLength":
			n.maxLength = countOf(val)
		case "minLength":
			n.minLength = countOf(val)
		case "maxItems":
			n.maxItems = countOf(val)
		case "minItems":
			n.minItems = countOf(val)
		case "maxProperties":
			n.maxProperties = countOf(val)
		case "minProperties":
			n.minProperties = countOf(val)
		case "maxContains":
			n.maxContains = countOf(val)
		case "minContains":
			n.minContains = countOf(val)
		case "pattern":
			if val.Kind() == jsonvalue.KindString {
				n.pattern = b.pattern(val.Str())
			}
		case "uniqueItems":
			n.uniqueItems = val.Kind() == jsonvalue.KindBool && val.Bool()
		case "required":
			n.required = stringList(val)
		case "dependentRequired":
			if val.Kind() == jsonvalue.KindObject {
				for _, dm := range val.Object().Members() {
					n.dependentRequired = append(n.dependentRequired, depRequired{dm.Key, stringList(&dm.Value)})
				}
			}
		case "prefixItems":
			n.prefixItems = b.walkList(val, base)
		case "items":
			n.items = b.walk(val, base)
		case "contains":
			n.contains = b.walk(val, base)
		case "properties":
			if val.Kind() == jsonvalue.KindObject {
				ms := val.Object().Members()
				n.properties = make(map[string]*node, len(ms))
				for j := range ms {
					n.properties[ms[j].Key] = b.walk(&ms[j].Value, base)
				}
			}
		case "patternProperties":
			if val.Kind() == jsonvalue.KindObject {
				ms := val.Object().Members()
				for j := range ms {
					n.patternProperties = append(n.patternProperties,
						patternProp{b.pattern(ms[j].Key), b.walk(&ms[j].Value, base)})
				}
			}
		case "additionalProperties":
			n.additionalProperties = b.walk(val, base)
		case "propertyNames":
			n.propertyNames = b.walk(val, base)
		case "dependentSchemas":
			if val.Kind() == jsonvalue.KindObject {
				ms := val.Object().Members()
				for j := range ms {
					n.dependentSchemas = append(n.dependentSchemas, depSchema{ms[j].Key, b.walk(&ms[j].Value, base)})
				}
			}
		case "allOf":
			n.allOf = b.walkList(val, base)
		case "anyOf":
			n.anyOf = b.walkList(val, base)
		case "oneOf":
			n.oneOf = b.walkList(val, base)
		case "not":
			n.not = b.walk(val, base)
		case "if":
			n.ifNode = b.walk(val, base)
		case "then":
			n.thenNode = b.walk(val, base)
		case "else":
			n.elseNode = b.walk(val, base)
		case "unevaluatedItems":
			n.unevaluatedItems = b.walk(val, base)
			n.hasUneval = true
		case "unevaluatedProperties":
			n.unevaluatedProperties = b.walk(val, base)
			n.hasUneval = true
		case "$defs":
			if val.Kind() == jsonvalue.KindObject {
				ms := val.Object().Members()
				for j := range ms {
					b.walk(&ms[j].Value, base)
				}
			}
		case "contentSchema":
			b.walk(val, base)
		case "$ref":
			if val.Kind() == jsonvalue.KindString {
				n.hasRef, n.refStr = true, val.Str()
			}
		case "$dynamicRef":
			if val.Kind() == jsonvalue.KindString {
				n.hasDynRef, n.dynRefStr = true, val.Str()
			}
		}
	}
	if n.hasRef || n.hasDynRef {
		b.refNodes = append(b.refNodes, n)
	}
	return n
}

func (b *builder) walkList(v *jsonvalue.Value, base string) []*node {
	if v.Kind() != jsonvalue.KindArray {
		return nil
	}
	arr := v.Array()
	out := make([]*node, len(arr))
	for i := range arr {
		out[i] = b.walk(&arr[i], base)
	}
	return out
}

func stringList(v *jsonvalue.Value) []string {
	if v.Kind() != jsonvalue.KindArray {
		return nil
	}
	var out []string
	for _, e := range v.Array() {
		if e.Kind() == jsonvalue.KindString {
			out = append(out, e.Str())
		}
	}
	return out
}

// resolveAll resolves every $ref and $dynamicRef once, after all documents
// have been indexed.
func (b *builder) resolveAll() {
	for _, n := range b.refNodes {
		base := b.strs[n.base]
		if n.hasRef {
			n.ref, _, n.refErr = b.resolve(base, n.refStr)
		}
		if n.hasDynRef {
			var doc string
			var frag string
			n.dynRef, doc, n.dynRefErr = b.resolve(base, n.dynRefStr)
			// Dynamic if the fragment is a plain name that is a dynamic
			// anchor under the resolved document.
			full := uri.Resolve(base, n.dynRefStr)
			_, frag, _ = uri.SplitFragment(full)
			frag = uri.PercentDecode(frag)
			if frag != "" && frag[0] != '/' {
				if docID, ok := b.ids[doc]; ok {
					if nameID, ok := b.ids[frag]; ok {
						if _, ok := b.dynamic[anchorKey{docID, nameID}]; ok {
							n.dynName = nameID
						}
					}
				}
			}
		}
	}
}

// resolve resolves reference ref against base and returns the target node and
// the document part of the resolved URI.
func (b *builder) resolve(base, ref string) (*node, string, error) {
	full := uri.Resolve(base, ref)
	doc, frag, _ := uri.SplitFragment(full)
	frag = uri.PercentDecode(frag)
	res := b.resources[doc]
	if res == nil {
		return nil, doc, fmt.Errorf("jsonschema: reference %q: no schema resource %q", ref, doc)
	}
	switch {
	case frag == "":
		return res.node, doc, nil
	case frag[0] == '/':
		if target := jsonpointer.Resolve(res.val, frag); target != nil {
			if n := b.byValue[target]; n != nil {
				return n, doc, nil
			}
		}
		return nil, doc, fmt.Errorf("jsonschema: reference %q: pointer %q does not designate a schema", ref, frag)
	}
	if docID, ok := b.ids[doc]; ok {
		if nameID, ok := b.ids[frag]; ok {
			k := anchorKey{docID, nameID}
			if n, ok := b.anchors[k]; ok {
				return n, doc, nil
			}
			if n, ok := b.dynamic[k]; ok {
				return n, doc, nil
			}
		}
	}
	return nil, doc, fmt.Errorf("jsonschema: reference %q: unknown anchor %q in %q", ref, frag, doc)
}
