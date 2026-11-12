package jsonschema_test

import (
	"fmt"

	"example.com/jsonschema"
	"example.com/jsonschema/jsonvalue"
)

func Example() {
	schema, err := jsonschema.CompileJSON([]byte(`{"type":"integer","minimum":1}`))
	if err != nil {
		panic(err)
	}
	for _, doc := range []string{`3`, `0`, `"3"`} {
		ok, err := schema.ValidateJSON([]byte(doc))
		if err != nil {
			panic(err)
		}
		fmt.Println(doc, ok)
	}
	// Output:
	// 3 true
	// 0 false
	// "3" false
}

func ExampleCompiler() {
	var c jsonschema.Compiler
	// A document the schema refers to by absolute URI; nothing is fetched.
	c.AddResource("http://example.com/positive.json",
		mustParse(`{"type":"number","exclusiveMinimum":0}`))

	schema, err := c.Compile(mustParse(`{
		"type": "object",
		"properties": {"price": {"$ref": "http://example.com/positive.json"}},
		"required": ["price"]
	}`))
	if err != nil {
		panic(err)
	}
	fmt.Println(schema.Validate(mustParse(`{"price": 9.99}`)))
	fmt.Println(schema.Validate(mustParse(`{"price": 0}`)))
	// Output:
	// true
	// false
}

func ExampleSchema_Validate_unevaluatedProperties() {
	schema, _ := jsonschema.CompileJSON([]byte(`{
		"allOf": [{"properties": {"a": true}}, {"properties": {"b": true}}],
		"unevaluatedProperties": false
	}`))
	fmt.Println(schema.Validate(mustParse(`{"a": 1, "b": 2}`)))
	fmt.Println(schema.Validate(mustParse(`{"a": 1, "c": 3}`)))
	// Output:
	// true
	// false
}

func mustParse(s string) jsonvalue.Value {
	v, err := jsonvalue.ParseString(s)
	if err != nil {
		panic(err)
	}
	return v
}
