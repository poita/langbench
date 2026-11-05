package syntax

import "testing"

func TestParseGroupsAndKinds(t *testing.T) {
	tree, err := Parse(`(a|(b))+c{2,3}[x-z]`)
	if err != nil {
		t.Fatal(err)
	}
	if tree.NumGroups != 2 {
		t.Errorf("NumGroups = %d, want 2", tree.NumGroups)
	}
	if tree.Root.Kind != KindSeq || len(tree.Root.Subs) != 3 {
		t.Fatalf("root = %+v", tree.Root)
	}
	rep := tree.Root.Subs[0]
	if rep.Kind != KindRep || rep.Min != 1 || rep.Max != Unbounded {
		t.Errorf("first piece = %+v", rep)
	}
	c := tree.Root.Subs[1]
	if c.Kind != KindRep || c.Min != 2 || c.Max != 3 {
		t.Errorf("second piece = %+v", c)
	}
}

func TestClassContents(t *testing.T) {
	tests := []struct {
		pat string
		in  string
		out string
	}{
		{`[a-c]`, "abc", "xyz-"},
		{`[^a-c]`, "xyz", "abc"},
		{`[-ab]`, "-ab", "c"},
		{`[ab-]`, "-ab", "c"},
		{`[a\-c]`, "a-c", "b"},
		{`[\d_]`, "5_", "a"},
		{`[^\W]`, "a_Z9", "-"},
		{`\s`, " ", "x"},
		{`\S`, "x", " "},
		{`[\]\\]`, `]\`, "a"},
	}
	for _, tc := range tests {
		tree, err := Parse(tc.pat)
		if err != nil {
			t.Errorf("Parse(%q): %v", tc.pat, err)
			continue
		}
		set := tree.Root.Set
		for i := 0; i < len(tc.in); i++ {
			if !set.Has(tc.in[i]) {
				t.Errorf("%s should contain %q", tc.pat, tc.in[i])
			}
		}
		for i := 0; i < len(tc.out); i++ {
			if set.Has(tc.out[i]) {
				t.Errorf("%s should not contain %q", tc.pat, tc.out[i])
			}
		}
	}
}

func TestParseErrors(t *testing.T) {
	for _, pat := range []string{`(`, `a)`, `[`, `[z-a]`, `a{3,2}`, `a{x}`, `**`, `\1`, `$+`} {
		if _, err := Parse(pat); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", pat)
		}
	}
}

func TestAnalysis(t *testing.T) {
	tests := []struct {
		pat      string
		anchored bool
		nullable bool
		first    string // characters expected in the first set ("" with nullable: don't care)
	}{
		{`^abc`, true, false, "a"},
		{`^a|^b`, true, false, "ab"},
		{`^a|b`, false, false, "ab"},
		{`(^a)+`, true, false, "a"},
		{`(^a)*`, false, true, ""},
		{`a*b`, false, false, "ab"},
		{`a?`, false, true, ""},
		{`$`, false, true, ""},
		{`a{0}b`, false, false, "ab"},
		{`(a|)b`, false, false, "ab"},
		{``, false, true, ""},
	}
	for _, tc := range tests {
		tree, err := Parse(tc.pat)
		if err != nil {
			t.Fatal(err)
		}
		if got := tree.Root.Anchored(); got != tc.anchored {
			t.Errorf("%q Anchored = %v", tc.pat, got)
		}
		var set CharSet
		nullable := tree.Root.AddFirst(&set)
		if nullable != tc.nullable || nullable != tree.Root.Nullable() {
			t.Errorf("%q nullable = %v, want %v", tc.pat, nullable, tc.nullable)
		}
		for i := 0; i < len(tc.first); i++ {
			if !set.Has(tc.first[i]) {
				t.Errorf("%q first set lacks %q", tc.pat, tc.first[i])
			}
		}
	}
}
