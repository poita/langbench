package xmlmini

import "testing"

func TestParseBasics(t *testing.T) {
	src := `<?xml version="1.0"?>
<!DOCTYPE svg [ <!ENTITY x "<a>"> ]>
<!-- a <comment> -->
<svg:svg xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="x" a = 'b' c="d>e">
  text <![CDATA[ <ignored/> ]]>
  <g id="1"><rect xlink:href="#r" x="1" x="2"/></g>
  <circle/>
</svg:svg>`
	root, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if root.Tag != "svg" {
		t.Fatalf("root tag = %q", root.Tag)
	}
	if v, _ := root.Attr("a"); v != "b" {
		t.Errorf("a = %q", v)
	}
	if v, _ := root.Attr("c"); v != "d>e" {
		t.Errorf("c = %q, want quoted > preserved", v)
	}
	if _, ok := root.Attr("xlink"); ok {
		t.Error("xmlns:xlink should be dropped")
	}
	if len(root.Children) != 2 {
		t.Fatalf("children = %d, want 2", len(root.Children))
	}
	rect := root.Children[0].Children[0]
	if rect.Tag != "rect" {
		t.Fatalf("tag = %q", rect.Tag)
	}
	if v, _ := rect.Attr("href"); v != "#r" {
		t.Errorf("href = %q", v)
	}
	if v, _ := rect.Attr("x"); v != "2" {
		t.Errorf("duplicate attribute: last should win, got %q", v)
	}
}

func TestEntities(t *testing.T) {
	root, err := Parse([]byte(`<svg a="&amp;&lt;&gt;&quot;&apos;&#65;&#x42;&nbsp;&#xZZ;"/>`))
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := root.Attr("a"); v != `&<>"'AB&nbsp;&#xZZ;` {
		t.Errorf("a = %q", v)
	}
}

func TestNoRoot(t *testing.T) {
	if _, err := Parse([]byte("just text <!-- c -->")); err != ErrNoRoot {
		t.Errorf("err = %v, want ErrNoRoot", err)
	}
}

func TestUnclosed(t *testing.T) {
	root, err := Parse([]byte(`<svg><g><rect/>`))
	if err != nil || len(root.Children) != 1 || len(root.Children[0].Children) != 1 {
		t.Errorf("lenient parse failed: %v %+v", err, root)
	}
}
