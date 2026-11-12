// Command jsonschema validates JSON instances against a JSON Schema draft
// 2020-12 schema.
//
// It reads one JSON document from standard input of the form
//
//	{"schema": ..., "tests": [{"description": "...", "data": ...}, ...],
//	 "remotes": {"http://example.com/other.json": {...}}}
//
// and prints "valid" or "invalid" for each element of "tests", one per line.
// "remotes" is optional and supplies the documents that the schema refers to by
// absolute URI. The exit status is 0 on success, 1 for malformed input.
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/jsonschema"
	"example.com/jsonschema/jsonvalue"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr))
}

// run executes the command and returns the process exit status.
func run(stdin io.Reader, stdout, stderr io.Writer) int {
	out, err := process(stdin)
	if err != nil {
		fmt.Fprintf(stderr, "jsonschema: %v\n", err)
		return 1
	}
	if _, err := io.WriteString(stdout, out); err != nil {
		fmt.Fprintf(stderr, "jsonschema: %v\n", err)
		return 1
	}
	return 0
}

// process reads a request and returns the verdict lines.
func process(r io.Reader) (string, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return "", err
	}
	req, err := jsonvalue.Parse(data)
	if err != nil {
		return "", err
	}
	obj, ok := req.Object()
	if !ok {
		return "", fmt.Errorf("input must be a JSON object")
	}
	schemaV, ok := obj.Get("schema")
	if !ok {
		return "", fmt.Errorf(`missing "schema" member`)
	}
	testsV, ok := obj.Get("tests")
	if !ok {
		return "", fmt.Errorf(`missing "tests" member`)
	}
	tests, ok := testsV.Array()
	if !ok {
		return "", fmt.Errorf(`"tests" must be an array`)
	}

	var c jsonschema.Compiler
	if rv, ok := obj.Get("remotes"); ok {
		remotes, ok := rv.Object()
		if !ok {
			return "", fmt.Errorf(`"remotes" must be an object`)
		}
		for i := 0; i < remotes.Len(); i++ {
			uri, doc := remotes.At(i)
			c.AddResource(uri, doc)
		}
	}
	schema, err := c.Compile(schemaV)
	if err != nil {
		return "", err
	}

	out := make([]byte, 0, len(tests)*8)
	for i, t := range tests {
		to, ok := t.Object()
		if !ok {
			return "", fmt.Errorf("tests[%d] must be an object", i)
		}
		data, ok := to.Get("data")
		if !ok {
			return "", fmt.Errorf(`tests[%d] has no "data" member`, i)
		}
		if schema.Validate(data) {
			out = append(out, "valid\n"...)
		} else {
			out = append(out, "invalid\n"...)
		}
	}
	return string(out), nil
}
