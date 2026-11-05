// Command jsonschema validates JSON instances against a JSON Schema draft
// 2020-12 schema.
//
// It reads one JSON document from standard input:
//
//	{"schema": <schema>, "tests": [{"description": "...", "data": <instance>}, ...],
//	 "remotes": {"<absolute URI>": <schema document>, ...}}
//
// and prints "valid" or "invalid" for each test, one per line, in order.
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/jsonschema"
	"example.com/jsonschema/jsonvalue"
)

func main() {
	if err := run(os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "jsonschema:", err)
		os.Exit(1)
	}
}

// run reads the request from in and writes the verdicts to out. Problems that
// affect a single instance (such as an unresolvable reference reached while
// validating it) are reported on warn and the instance is printed as invalid.
func run(in io.Reader, out, warn io.Writer) error {
	input, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	req, err := jsonvalue.Parse(input)
	if err != nil {
		return err
	}
	if req.Kind() != jsonvalue.KindObject {
		return fmt.Errorf("input must be a JSON object")
	}
	obj := req.Object()
	schemaDoc := obj.Get("schema")
	tests := obj.Get("tests")
	if schemaDoc == nil {
		return fmt.Errorf(`missing "schema" member`)
	}
	if tests == nil || tests.Kind() != jsonvalue.KindArray {
		return fmt.Errorf(`"tests" must be an array`)
	}

	compiler := jsonschema.NewCompiler()
	if remotes := obj.Get("remotes"); remotes != nil && remotes.Kind() == jsonvalue.KindObject {
		for _, m := range remotes.Object().Members() {
			compiler.AddResource(m.Key, m.Value)
		}
	}
	schema, err := compiler.Compile(*schemaDoc)
	if err != nil {
		return err
	}

	buf := make([]byte, 0, 8*len(tests.Array()))
	for i, t := range tests.Array() {
		valid := false
		if t.Kind() == jsonvalue.KindObject {
			if data := t.Object().Get("data"); data != nil {
				var err error
				valid, err = schema.Validate(*data)
				if err != nil {
					fmt.Fprintf(warn, "jsonschema: test %d: %v\n", i, err)
				}
			}
		}
		if valid {
			buf = append(buf, "valid\n"...)
		} else {
			buf = append(buf, "invalid\n"...)
		}
	}
	_, err = out.Write(buf)
	return err
}
