package index

import (
	"reflect"
	"testing"

	"fulltext/analysis"
)

func build(docs map[string]string) *Index {
	b := NewBuilder(analysis.NewAnalyzer())
	for id, text := range docs {
		b.Add(id, text)
	}
	return b.Build()
}

func TestBuild(t *testing.T) {
	ix := build(map[string]string{
		"b": "the cat sat. The cat!",
		"a": "dog",
		"c": "",
	})
	if ix.NumDocs() != 3 || ix.NumTokens() != 6 || ix.NumTerms() != 4 {
		t.Fatalf("docs=%d tokens=%d terms=%d", ix.NumDocs(), ix.NumTokens(), ix.NumTerms())
	}
	if got := ix.AvgDocLen(); got != 2 {
		t.Errorf("AvgDocLen = %v", got)
	}
	var ids []string
	for i := 0; i < ix.NumDocs(); i++ {
		ids = append(ids, ix.Doc(i).ID)
	}
	if !reflect.DeepEqual(ids, []string{"a", "b", "c"}) {
		t.Errorf("ids = %v", ids)
	}
	p, ok := ix.Postings("cat")
	if !ok || p.Len() != 1 || p.Docs[0] != 1 {
		t.Fatalf("postings(cat) = %+v", p)
	}
	if got := p.Positions(0); !reflect.DeepEqual(got, []int32{1, 4}) {
		t.Errorf("positions = %v", got)
	}
	if p.Find(1) != 0 || p.Find(0) != -1 || p.Find(2) != -1 {
		t.Error("Find misbehaves")
	}
	if _, ok := ix.Postings("zebra"); ok {
		t.Error("unexpected posting")
	}
}

func TestTokenSpan(t *testing.T) {
	ix := build(map[string]string{"d": "  Hello, wörld!  "})
	d := ix.Doc(0)
	s, e := d.TokenSpan(1)
	if d.Text[s:e] != "wörld" || d.Len != 2 {
		t.Errorf("span = %q, len %d", d.Text[s:e], d.Len)
	}
}

func TestEmptyIndex(t *testing.T) {
	ix := build(nil)
	if ix.NumDocs() != 0 || ix.AvgDocLen() != 0 || ix.NumTerms() != 0 {
		t.Error("empty index should be empty")
	}
}

func TestMultiDocPostings(t *testing.T) {
	ix := build(map[string]string{"x": "go go", "y": "stop", "z": "go"})
	p, _ := ix.Postings("go")
	if !reflect.DeepEqual(p.Docs, []int32{0, 2}) ||
		!reflect.DeepEqual(p.Positions(0), []int32{0, 1}) ||
		!reflect.DeepEqual(p.Positions(1), []int32{0}) {
		t.Errorf("postings = %+v", p)
	}
}
