package xmlmini

import "testing"

func TestParseBasics(t *testing.T) {
	src := `<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x "<a>">]><!-- c -->
<svg:svg xmlns:svg="u" xlink:href='#a' a="1" a="2">
  <![CDATA[ <ignored> ]]>
  <rect title="a&gt;b &amp; &#65;&#x42; &bogus;" d="x>y"/>
  <g><path/></g >
</svg:svg>`
	root, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if root.Tag != "svg" {
		t.Fatalf("tag %q", root.Tag)
	}
	if v, _ := root.Attr("href"); v != "#a" {
		t.Errorf("href = %q", v)
	}
	if v, _ := root.Attr("a"); v != "2" {
		t.Errorf("duplicate attribute: last must win, got %q", v)
	}
	if len(root.Children) != 2 {
		t.Fatalf("children = %d", len(root.Children))
	}
	rect := root.Children[0]
	if v, _ := rect.Attr("title"); v != "a>b & AB &bogus;" {
		t.Errorf("title = %q", v)
	}
	if v, _ := rect.Attr("d"); v != "x>y" {
		t.Errorf("d = %q", v)
	}
	if g := root.Children[1]; g.Tag != "g" || len(g.Children) != 1 || g.Children[0].Tag != "path" {
		t.Errorf("bad g subtree: %+v", g)
	}
}

func TestSelfClosingWithSpace(t *testing.T) {
	root, err := Parse([]byte(`<svg><rect a = "1" /><circle/></svg>`))
	if err != nil {
		t.Fatal(err)
	}
	if len(root.Children) != 2 {
		t.Fatalf("children = %d", len(root.Children))
	}
	if v, _ := root.Children[0].Attr("a"); v != "1" {
		t.Errorf("a = %q", v)
	}
}

func TestErrors(t *testing.T) {
	for _, s := range []string{"", "no tags", "<svg", "<!-- x", `<svg a="1>`} {
		if _, err := Parse([]byte(s)); err == nil {
			t.Errorf("Parse(%q) succeeded", s)
		}
	}
}
