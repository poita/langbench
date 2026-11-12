package registry

import (
	"strings"
	"testing"

	"depresolve/semver"
)

func TestParse(t *testing.T) {
	src := "a 1.0.0: c ^1.0.0, d *\n" +
		"c 1.2.0:\n" +
		"a 1.10.0: c >=1.0.0 <2.0.0\n" +
		"c 1.10.0:\n" +
		"root: a *, c ~1.2.0\n"
	in, err := Parse(strings.NewReader(src))
	if err != nil {
		t.Fatal(err)
	}
	if got := in.Registry.Packages(); len(got) != 2 || got[0] != "a" || got[1] != "c" {
		t.Errorf("Packages() = %v", got)
	}
	rel := in.Registry.Releases("a")
	if len(rel) != 2 || rel[0].Version.String() != "1.10.0" || rel[1].Version.String() != "1.0.0" {
		t.Errorf("a releases not newest first: %+v", rel)
	}
	if len(rel[1].Requires) != 2 || rel[1].Requires[1].Package != "d" || rel[1].Requires[1].Range != semver.Any {
		t.Errorf("requirements of a 1.0.0 = %+v", rel[1].Requires)
	}
	if len(in.Root) != 2 || in.Root[1].Package != "c" {
		t.Errorf("root = %+v", in.Root)
	}
	if in.Registry.Releases("zzz") != nil {
		t.Error("unknown package should have no releases")
	}
}

func TestParseEmptyRoot(t *testing.T) {
	in, err := Parse(strings.NewReader("root:\n"))
	if err != nil || len(in.Root) != 0 || len(in.Registry.Packages()) != 0 {
		t.Fatalf("Parse = %+v, %v", in, err)
	}
}

func TestParseErrors(t *testing.T) {
	for name, src := range map[string]string{
		"empty":         "",
		"no root":       "a 1.0.0:\n",
		"after root":    "root:\na 1.0.0:\n",
		"no colon":      "a 1.0.0\nroot:\n",
		"bad version":   "a 1.0: \nroot:\n",
		"bad name":      "1.0.0: \nroot:\n",
		"bad req":       "a 1.0.0: b\nroot:\n",
		"bad range":     "a 1.0.0: b ^x\nroot:\n",
		"duplicate":     "a 1.0.0:\na 1.0.0:\nroot:\n",
		"missing space": "a 1.0.0:b *\nroot:\n",
	} {
		if _, err := Parse(strings.NewReader(src)); err == nil {
			t.Errorf("%s: Parse succeeded, want error", name)
		}
	}
}

func TestParseWithoutTrailingNewline(t *testing.T) {
	in, err := Parse(strings.NewReader("a 1.0.0:\nroot: a *"))
	if err != nil || len(in.Root) != 1 {
		t.Fatalf("Parse = %+v, %v", in, err)
	}
}
