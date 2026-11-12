package sitegen_test

import (
	"fmt"
	"testing/fstest"

	"example.com/sitegen"
)

func ExampleBuild() {
	src := fstest.MapFS{
		"site.toml":              {Data: []byte("title = \"Demo\"\nbase_url = \"https://demo.test\"\nauthor = \"Me\"\nposts_per_page = 10\n")},
		"content/posts/hello.md": {Data: []byte("+++\ntitle = \"Hello\"\ndate = \"2024-03-05\"\n+++\nHi *there*.\n")},
		"templates/index.html":   {Data: []byte(`{% for p in posts %}{{ p.title }} ({{ p.date_long }}){% endfor %}`)},
		"templates/post.html":    {Data: []byte(`{{ post.content }}`)},
		"templates/page.html":    {Data: []byte(``)},
		"templates/tag.html":     {Data: []byte(``)},
		"templates/tags.html":    {Data: []byte(``)},
	}
	out := sitegen.MemSink{}
	if err := sitegen.Build(src, out); err != nil {
		panic(err)
	}
	fmt.Println(string(out["index.html"]))
	fmt.Print(string(out["posts/hello/index.html"]))
	// Output:
	// Hello (March 5, 2024)
	// <p>Hi <em>there</em>.</p>
}
