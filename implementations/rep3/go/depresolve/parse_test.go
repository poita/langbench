package depresolve

import (
	"strings"
	"testing"
)

func TestParseOK(t *testing.T) {
	in := "a 1.0.0: b ^1.0.0, c >=1.0.0 <2.0.0\nb 1.0.0:\nroot: a *\n"
	p, err := Parse(in)
	if err != nil {
		t.Fatal(err)
	}
	if p.Packages() != 3 {
		t.Errorf("Packages() = %d; want 3", p.Packages())
	}
	if p.rootCount != 1 {
		t.Errorf("root has %d requirements; want 1", p.rootCount)
	}
	// Missing final newline is tolerated.
	if _, err := Parse("root:"); err != nil {
		t.Errorf("Parse without final newline: %v", err)
	}
}

func TestParseWindows(t *testing.T) {
	in := "a 1.0.0:\na 1.2.0:\na 1.1.0:\na 2.0.0:\nroot: a ^1.0.0, a *, a >5.0.0, ghost *, a 1.1.0\n"
	p, err := Parse(in)
	if err != nil {
		t.Fatal(err)
	}
	want := [][2]int32{{1, 4}, {0, 4}, {0, 0}, {0, 0}, {2, 3}}
	for i, w := range want {
		r := p.reqs[int(p.rootStart)+i]
		got := [2]int32{r.first, r.last}
		if r.first >= r.last {
			got = [2]int32{0, 0}
		}
		if got != w {
			t.Errorf("root requirement %d: window %v; want %v", i, got, w)
		}
	}
	// Versions of "a" are stored newest first.
	var keys []uint64
	for _, v := range p.vers {
		keys = append(keys, v.key)
	}
	for i := 1; i < len(keys); i++ {
		if keys[i-1] <= keys[i] {
			t.Errorf("versions not sorted newest first: %v", keys)
		}
	}
}

func TestParseErrors(t *testing.T) {
	bad := []string{
		"",                      // no root
		"a 1.0.0:\n",            // no root
		"root: a\nroot:\n",      // data after root
		"root: a *\na 1.0.0:\n", // root not last
		"a 1.0.0 b\nroot:\n",    // no colon
		"a1.0.0:\nroot:\n",      // no space
		"A 1.0.0:\nroot:\n",     // bad name
		"a 01.0.0:\nroot:\n",    // leading zero
		"a 1.0.0:b *\nroot:\n",  // missing space
		"a 1.0.0: b\nroot:\n",   // requirement without range
		"a 1.0.0: b ^1\nroot:\n",
		"root: a *,b *\n",
		"root: a *, \n",
		"a 1.0.0:\na 1.0.0:\nroot:\n", // duplicate
	}
	for _, in := range bad {
		if _, err := Parse(in); err == nil {
			t.Errorf("Parse(%q) succeeded; want error", in)
		}
	}
}

func TestParseReader(t *testing.T) {
	p, err := ParseReader(strings.NewReader("a 1.0.0:\nroot: a *\n"))
	if err != nil {
		t.Fatal(err)
	}
	res, err := p.Resolve()
	if err != nil || res.String() != "a 1.0.0\n" {
		t.Errorf("got %q, %v", res, err)
	}
}

func TestBuilderValidation(t *testing.T) {
	var b Builder
	b.AddVersion("Bad", Version{1, 0, 0})
	if _, err := b.Build(); err == nil {
		t.Error("invalid name accepted")
	}
	b = Builder{}
	b.AddVersion("a", Version{1, 0, 0}, Requirement{"b c", AnyVersion})
	if _, err := b.Build(); err == nil {
		t.Error("invalid requirement name accepted")
	}
	b = Builder{}
	b.AddVersion("a", Version{MaxComponent + 1, 0, 0})
	if _, err := b.Build(); err == nil {
		t.Error("oversized component accepted")
	}
	b = Builder{}
	b.SetRoot(Requirement{"", AnyVersion})
	if _, err := b.Build(); err == nil {
		t.Error("empty root requirement name accepted")
	}
}

func TestValidName(t *testing.T) {
	for s, want := range map[string]bool{
		"a": true, "my-lib2": true, "abcdefghijklmnop": true,
		"": false, "abcdefghijklmnopq": false, "1a": false, "-a": false, "a_b": false, "A": false,
	} {
		if ValidName(s) != want {
			t.Errorf("ValidName(%q) = %v", s, !want)
		}
	}
}
