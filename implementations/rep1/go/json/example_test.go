package jsoncanon_test

import (
	"fmt"

	"example.com/jsoncanon"
)

func ExampleCanonicalize() {
	out, err := jsoncanon.Canonicalize([]byte(`{ "b": [1, 2.50, 1E+3], "a": "x", "b": null }`))
	fmt.Println(string(out), err)
	// Output: {"a":"x","b":null} <nil>
}

func ExampleCanonicalize_invalid() {
	_, err := jsoncanon.Canonicalize([]byte(`[1, 2, ]`))
	fmt.Println(err)
	// Output: jsoncanon: unexpected character at offset 7
}
