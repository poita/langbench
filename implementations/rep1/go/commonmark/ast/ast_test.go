package ast

import "testing"

func kids(n *Node) string {
	s := ""
	for c := n.FirstChild; c != nil; c = c.Next {
		s += c.Literal
	}
	return s
}

func list(lits ...string) (*Node, []*Node) {
	p := New(Paragraph)
	var ns []*Node
	for _, l := range lits {
		n := &Node{Kind: Text, Literal: l}
		p.AppendChild(n)
		ns = append(ns, n)
	}
	return p, ns
}

func TestAppendUnlinkInsert(t *testing.T) {
	p, ns := list("a", "b", "c")
	if got := kids(p); got != "abc" {
		t.Fatalf("got %q", got)
	}
	ns[1].Unlink()
	if got := kids(p); got != "ac" {
		t.Fatalf("after unlink got %q", got)
	}
	ns[2].Unlink()
	ns[0].InsertAfter(ns[1])
	if got := kids(p); got != "ab" || p.LastChild != ns[1] {
		t.Fatalf("after insert got %q", got)
	}
	ns[0].Unlink()
	ns[1].Unlink()
	if p.FirstChild != nil || p.LastChild != nil {
		t.Fatal("expected empty parent")
	}
}

func TestAdoptRange(t *testing.T) {
	p, ns := list("a", "b", "c", "d")
	e := New(Emph)
	e.AdoptRange(ns[1], ns[2])
	if kids(p) != "ad" || kids(e) != "bc" {
		t.Fatalf("got %q / %q", kids(p), kids(e))
	}
	if ns[1].Parent != e || ns[2].Parent != e || e.LastChild != ns[2] {
		t.Fatal("parents not updated")
	}
	ns[0].InsertAfter(e)
	if p.FirstChild != ns[0] || p.LastChild != ns[3] || ns[0].Next != e || e.Next != ns[3] {
		t.Fatal("bad links after insert")
	}
}

func TestWalk(t *testing.T) {
	doc := New(Document)
	p := New(Paragraph)
	doc.AppendChild(p)
	p.AppendChild(&Node{Kind: Text})
	em := New(Emph)
	p.AppendChild(em)
	var trace []string
	Walk(doc, func(n *Node, entering bool) WalkStatus {
		s := n.Kind.String()
		if !entering {
			s = "/" + s
		}
		trace = append(trace, s)
		return Continue
	})
	want := "document paragraph text /text emph /emph /paragraph /document"
	got := ""
	for i, s := range trace {
		if i > 0 {
			got += " "
		}
		got += s
	}
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestKind(t *testing.T) {
	if !CodeBlock.IsBlock() || Text.IsBlock() {
		t.Error("IsBlock misclassifies kinds")
	}
	if Link.String() != "link" {
		t.Errorf("Link.String() = %q", Link.String())
	}
}
