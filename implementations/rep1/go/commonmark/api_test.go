package commonmark_test

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"example.com/commonmark"
)

func ExampleToHTML() {
	fmt.Print(string(commonmark.ToHTML([]byte("# Hello\n\nSome *emphasis* and a [link](/url)."))))
	// Output:
	// <h1>Hello</h1>
	// <p>Some <em>emphasis</em> and a <a href="/url">link</a>.</p>
}

func ExampleParse() {
	doc := commonmark.Parse([]byte("- a\n- b\n"))
	var buf bytes.Buffer
	if _, err := doc.WriteTo(&buf); err != nil {
		panic(err)
	}
	fmt.Print(buf.String())
	// Output:
	// <ul>
	// <li>a</li>
	// <li>b</li>
	// </ul>
}

func TestDocumentRenderTwice(t *testing.T) {
	doc := commonmark.Parse([]byte("a *b*\n\n> c\n"))
	first, second := doc.HTML(), doc.HTML()
	if !bytes.Equal(first, second) {
		t.Errorf("rendering twice differs:\n%s\n%s", first, second)
	}
}

func TestWriteTo(t *testing.T) {
	var buf bytes.Buffer
	n, err := commonmark.Parse([]byte("x")).WriteTo(&buf)
	if err != nil || n != int64(buf.Len()) || buf.String() != "<p>x</p>\n" {
		t.Errorf("WriteTo = %d, %v, %q", n, err, buf.String())
	}
}

func TestInputNotModified(t *testing.T) {
	src := []byte("*a* `b`\n\n    c\n")
	orig := append([]byte(nil), src...)
	commonmark.ToHTML(src)
	if !bytes.Equal(src, orig) {
		t.Error("input was modified")
	}
}

func TestLinearOnPathologicalInput(t *testing.T) {
	// These would take minutes if the code span memo or the
	// openers_bottom bounds were missing.
	inputs := map[string]string{
		"backticks": strings.Repeat("`a ``b ", 50000),
		"stars":     strings.Repeat("*a ", 100000),
		"mixed":     strings.Repeat("_*", 100000) + "a",
		"brackets":  strings.Repeat("[", 50000) + strings.Repeat("]", 50000),
	}
	for name, in := range inputs {
		t.Run(name, func(t *testing.T) {
			commonmark.ToHTML([]byte(in))
		})
	}
}
