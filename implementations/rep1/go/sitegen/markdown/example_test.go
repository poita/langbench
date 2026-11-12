package markdown_test

import (
	"fmt"

	"example.com/sitegen/markdown"
)

func ExampleToHTML() {
	fmt.Print(markdown.ToHTML("# Title\n\nSome *emphasis*, **strong** text and a [link](/x \"t\").\n\n- one\n- two\n"))
	// Output:
	// <h1>Title</h1>
	// <p>Some <em>emphasis</em>, <strong>strong</strong> text and a <a href="/x" title="t">link</a>.</p>
	// <ul>
	// <li>one</li>
	// <li>two</li>
	// </ul>
}
