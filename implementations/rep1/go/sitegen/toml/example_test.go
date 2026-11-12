package toml_test

import (
	"fmt"

	"example.com/sitegen/toml"
)

func ExampleParse() {
	doc, err := toml.Parse(`title = "Hello" # greeting
draft = false
tags = ["a", "b"]
`)
	if err != nil {
		panic(err)
	}
	title, _ := doc.String("title")
	tags, _ := doc.Strings("tags")
	fmt.Println(title, tags)
	// Output: Hello [a b]
}
