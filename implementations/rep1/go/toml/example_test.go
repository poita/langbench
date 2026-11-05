package toml_test

import (
	"fmt"

	"github.com/example/toml"
)

func ExampleParse() {
	doc, err := toml.Parse([]byte("name = \"Tom\"\n[db]\nports = [8001, 8002]\n"))
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Println(string(doc.TaggedJSON()))
	// Output:
	// {"db":{"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"name":{"type":"string","value":"Tom"}}
}

func ExampleParseTaggedJSON() {
	doc, _ := toml.ParseTaggedJSON([]byte(`{"a":{"type":"integer","value":"1"},"t":{"x":{"type":"bool","value":"true"}}}`))
	fmt.Print(string(doc.TOML()))
	// Output:
	// a = 1
	//
	// [t]
	// x = true
}
