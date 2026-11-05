package jsonschema

import (
	"fmt"

	"example.com/jsonschema/jsonvalue"
)

// Schema is a compiled schema. It is immutable and safe for concurrent use by
// multiple goroutines.
type Schema struct {
	root       *node
	dynTargets map[anchorKey]*node
}

// Compile is a shorthand for NewCompiler().Compile(doc).
func Compile(doc jsonvalue.Value) (*Schema, error) {
	return NewCompiler().Compile(doc)
}

// CompileJSON parses a schema from JSON text and compiles it.
func CompileJSON(schema []byte) (*Schema, error) {
	doc, err := jsonvalue.Parse(schema)
	if err != nil {
		return nil, fmt.Errorf("jsonschema: parsing schema: %w", err)
	}
	return Compile(doc)
}

// Validate reports whether instance satisfies the schema. The error is
// non-nil only if evaluation reached a reference that does not resolve, an
// invalid regular expression, or exceeded the recursion limit; the boolean is
// then false.
func (s *Schema) Validate(instance jsonvalue.Value) (bool, error) {
	st := &state{schema: s}
	ok, _ := st.eval(s.root, &instance, false)
	if st.err != nil {
		return false, st.err
	}
	return ok, nil
}

// ValidateJSON parses instance from JSON text and validates it.
func (s *Schema) ValidateJSON(instance []byte) (bool, error) {
	v, err := jsonvalue.Parse(instance)
	if err != nil {
		return false, fmt.Errorf("jsonschema: parsing instance: %w", err)
	}
	return s.Validate(v)
}
