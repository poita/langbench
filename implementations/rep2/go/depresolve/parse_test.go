package depresolve

import (
	"errors"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	in := "a 1.0.0: b ^1.0.0, c >=1.0.0 <2.0.0\na 1.1.0:\nb 1.0.0:\nroot: a *\n"
	p, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Root) != 1 || p.Root[0].String() != "a *" {
		t.Errorf("root = %v", p.Root)
	}
	if got := p.Registry.NumPackages(); got != 3 { // a, b, c (c has no versions)
		t.Errorf("NumPackages = %d", got)
	}
	reqs, ok := p.Registry.Requirements("a", MustParseVersion("1.0.0"))
	if !ok || len(reqs) != 2 || reqs[1].String() != "c >=1.0.0 <2.0.0" {
		t.Errorf("requirements = %v, %v", reqs, ok)
	}
	vs := p.Registry.Versions("a")
	if len(vs) != 2 || vs[0].String() != "1.1.0" {
		t.Errorf("versions = %v", vs)
	}
	if p.Registry.Versions("zzz") != nil {
		t.Error("unknown package should have nil versions")
	}
	if _, ok := p.Registry.Requirements("a", MustParseVersion("9.9.9")); ok {
		t.Error("missing version reported present")
	}
}

func TestParseRootOnly(t *testing.T) {
	p, err := ParseBytes([]byte("root:\n"))
	if err != nil {
		t.Fatal(err)
	}
	res, err := p.Resolve()
	if err != nil || len(res) != 0 || res.String() != "" {
		t.Errorf("got %v, %v", res, err)
	}
}

func TestParseErrors(t *testing.T) {
	bad := map[string]string{
		"empty input":        "",
		"no root":            "a 1.0.0:\n",
		"content after root": "root:\na 1.0.0:\n",
		"no colon":           "a 1.0.0\nroot:\n",
		"bad version":        "a 1.0:\nroot:\n",
		"no space":           "a 1.0.0:b *\nroot:\n",
		"bad requirement":    "a 1.0.0: b\nroot:\n",
		"bad range":          "a 1.0.0: b ^x\nroot:\n",
		"duplicate version":  "a 1.0.0:\na 1.0.0:\nroot:\n",
		"missing name":       " 1.0.0:\nroot:\n",
	}
	for name, in := range bad {
		_, err := ParseBytes([]byte(in))
		var pe *ParseError
		if !errors.As(err, &pe) {
			t.Errorf("%s: err = %v, want *ParseError", name, err)
		} else if pe.Error() == "" || pe.Line < 1 {
			t.Errorf("%s: bad ParseError %+v", name, pe)
		}
	}
}

func TestParseMissingFinalNewline(t *testing.T) {
	if _, err := ParseBytes([]byte("a 1.0.0:\nroot: a *")); err != nil {
		t.Error(err)
	}
}
