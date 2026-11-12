package jsonschema

import (
	"fmt"
	"sort"

	"example.com/jsonschema/jsonvalue"
)

// Schema is a compiled JSON Schema. It is immutable and safe for concurrent
// use by multiple goroutines.
type Schema struct {
	root       *node
	dynamic    map[anchorKey]*node
	unresolved []string
}

// Compiler compiles schemas, optionally together with additional schema
// documents ("remotes") that the schema refers to by absolute URI. A Compiler
// never touches the network: every document a reference can reach must be
// supplied with AddResource.
//
// The zero Compiler is ready to use.
type Compiler struct {
	docs []remoteDoc
}

type remoteDoc struct {
	uri string
	doc jsonvalue.Value
}

// AddResource registers a schema document under its retrieval URI, the URI by
// which other schemas can refer to it. If the document declares an "$id" it is
// additionally registered under that. When two documents claim the same URI
// the one registered first (the root schema before any resource) wins.
func (c *Compiler) AddResource(uri string, doc jsonvalue.Value) {
	c.docs = append(c.docs, remoteDoc{uri, doc})
}

// Compile compiles schema, whose retrieval URI is the empty string, together
// with every resource added so far.
//
// Compile returns an error only for problems it can detect without evaluating
// anything, such as a "pattern" that is not a valid regular expression. A
// reference that cannot be resolved is not a compile error, because it may
// never be reached; see Schema.Unresolved and Schema.Validate.
//
// Keywords whose values have the wrong type (for example "minLength": "x") are
// ignored, in the same way as unknown keywords.
func (c *Compiler) Compile(schema jsonvalue.Value) (*Schema, error) {
	cc := newCompilation()
	root := cc.document("", schema)
	for _, d := range c.docs {
		cc.document(d.uri, d.doc)
	}
	if cc.err != nil {
		return nil, cc.err
	}
	cc.resolveRefs()
	if cc.err != nil {
		return nil, cc.err
	}
	s := &Schema{root: root, dynamic: cc.dynamic}
	for _, site := range cc.refs {
		if site.r.target == nil {
			s.unresolved = append(s.unresolved, fmt.Sprintf("%s: %s", site.r.text, site.r.err))
		}
	}
	sort.Strings(s.unresolved)
	return s, nil
}

// Compile compiles a single self-contained schema.
func Compile(schema jsonvalue.Value) (*Schema, error) {
	var c Compiler
	return c.Compile(schema)
}

// CompileJSON parses schemaJSON and compiles it as a single self-contained schema.
func CompileJSON(schemaJSON []byte) (*Schema, error) {
	v, err := jsonvalue.Parse(schemaJSON)
	if err != nil {
		return nil, err
	}
	return Compile(v)
}

// Validate reports whether instance satisfies the schema.
//
// A reference that was not resolvable at compile time makes the schema that
// contains it reject, if validation reaches it.
func (s *Schema) Validate(instance jsonvalue.Value) bool {
	e := evaluator{s: s, scope: make([]int32, 0, 16)}
	return e.eval(s.root, &instance, nil)
}

// ValidateJSON parses instanceJSON and validates it.
func (s *Schema) ValidateJSON(instanceJSON []byte) (bool, error) {
	v, err := jsonvalue.Parse(instanceJSON)
	if err != nil {
		return false, err
	}
	return s.Validate(v), nil
}

// Unresolved lists the references (as written, with the reason) that could not
// be resolved against the compiled documents. It is empty for a schema whose
// references all resolve.
func (s *Schema) Unresolved() []string { return s.unresolved }
