package uri

import "testing"

// The reference resolution examples of RFC 3986 section 5.4.
func TestResolveRFC3986Examples(t *testing.T) {
	const base = "http://a/b/c/d;p?q"
	tests := []struct{ ref, want string }{
		// normal
		{"g:h", "g:h"},
		{"g", "http://a/b/c/g"},
		{"./g", "http://a/b/c/g"},
		{"g/", "http://a/b/c/g/"},
		{"/g", "http://a/g"},
		{"//g", "http://g"},
		{"?y", "http://a/b/c/d;p?y"},
		{"g?y", "http://a/b/c/g?y"},
		{"#s", "http://a/b/c/d;p?q#s"},
		{"g#s", "http://a/b/c/g#s"},
		{"g?y#s", "http://a/b/c/g?y#s"},
		{";x", "http://a/b/c/;x"},
		{"g;x", "http://a/b/c/g;x"},
		{"g;x?y#s", "http://a/b/c/g;x?y#s"},
		{"", "http://a/b/c/d;p?q"},
		{".", "http://a/b/c/"},
		{"./", "http://a/b/c/"},
		{"..", "http://a/b/"},
		{"../", "http://a/b/"},
		{"../g", "http://a/b/g"},
		{"../..", "http://a/"},
		{"../../", "http://a/"},
		{"../../g", "http://a/g"},
		// abnormal
		{"../../../g", "http://a/g"},
		{"../../../../g", "http://a/g"},
		{"/./g", "http://a/g"},
		{"/../g", "http://a/g"},
		{"g.", "http://a/b/c/g."},
		{".g", "http://a/b/c/.g"},
		{"g..", "http://a/b/c/g.."},
		{"..g", "http://a/b/c/..g"},
		{"./../g", "http://a/b/g"},
		{"./g/.", "http://a/b/c/g/"},
		{"g/./h", "http://a/b/c/g/h"},
		{"g/../h", "http://a/b/c/h"},
		{"g;x=1/./y", "http://a/b/c/g;x=1/y"},
		{"g;x=1/../y", "http://a/b/c/y"},
		{"g?y/./x", "http://a/b/c/g?y/./x"},
		{"g?y/../x", "http://a/b/c/g?y/../x"},
		{"g#s/./x", "http://a/b/c/g#s/./x"},
		{"g#s/../x", "http://a/b/c/g#s/../x"},
		{"http:g", "http:g"},
	}
	for _, tc := range tests {
		if got := Resolve(base, tc.ref); got != tc.want {
			t.Errorf("Resolve(%q, %q) = %q, want %q", base, tc.ref, got, tc.want)
		}
	}
}

func TestResolveEdgeCases(t *testing.T) {
	tests := []struct{ base, ref, want string }{
		{"", "foo.json", "foo.json"},
		{"", "#/$defs/a", "#/$defs/a"},
		{"", "", ""},
		{"http://x", "y", "http://x/y"},
		{"http://x", "#f", "http://x#f"},
		{"urn:uuid:deadbeef", "#/$defs/bar", "urn:uuid:deadbeef#/$defs/bar"},
		{"urn:example:x", "urn:example:y", "urn:example:y"},
		{"http://localhost:1234/draft2020-12/root.json", "integer.json", "http://localhost:1234/draft2020-12/integer.json"},
		{"http://localhost:1234/a/b/", "../c.json#x", "http://localhost:1234/a/c.json#x"},
		{"foo/bar", "baz", "foo/baz"},
		{"http://x/y", "?q", "http://x/y?q"},
	}
	for _, tc := range tests {
		if got := Resolve(tc.base, tc.ref); got != tc.want {
			t.Errorf("Resolve(%q, %q) = %q, want %q", tc.base, tc.ref, got, tc.want)
		}
	}
}

func TestParseRoundTrip(t *testing.T) {
	for _, s := range []string{
		"http://u@h:80/p/q?x=1#f", "urn:a:b", "//h/p", "/p", "p", "?q", "#f", "", "http://h", "mailto:a@b", "a:b#c#d",
	} {
		if got := Parse(s).String(); got != s {
			t.Errorf("round trip %q -> %q", s, got)
		}
	}
	u := Parse("http://h:80/p?q#f")
	if u.Scheme != "http" || u.Authority != "h:80" || u.Path != "/p" || u.Query != "q" || u.Fragment != "f" {
		t.Errorf("components: %+v", u)
	}
	if u := Parse("1abc:x"); u.HasScheme {
		t.Error("scheme must start with a letter")
	}
}

func TestRemoveDotSegments(t *testing.T) {
	tests := map[string]string{
		"/a/b/c/./../../g":   "/a/g",
		"mid/content=5/../6": "mid/6",
		"/..":                "/",
		"a/..":               "/",
		"":                   "",
		"/a/./b":             "/a/b",
	}
	for in, want := range tests {
		if got := RemoveDotSegments(in); got != want {
			t.Errorf("RemoveDotSegments(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFragmentHelpers(t *testing.T) {
	doc, frag, ok := SplitFragment("http://x/y#/a/b")
	if doc != "http://x/y" || frag != "/a/b" || !ok {
		t.Errorf("SplitFragment = %q %q %v", doc, frag, ok)
	}
	if doc, frag, ok := SplitFragment("http://x/y"); doc != "http://x/y" || frag != "" || ok {
		t.Errorf("no fragment: %q %q %v", doc, frag, ok)
	}
	if StripFragment("a#b#c") != "a" {
		t.Error("StripFragment")
	}
}

func TestPercentDecode(t *testing.T) {
	tests := map[string]string{
		"/$defs/tilde~0field":    "/$defs/tilde~0field",
		"/$defs/percent%25field": "/$defs/percent%field",
		"%C3%A9":                 "é",
		"a%2Fb":                  "a/b",
		"100%":                   "100%",
		"%zz":                    "%zz",
		"%4":                     "%4",
		"plain":                  "plain",
	}
	for in, want := range tests {
		if got := PercentDecode(in); got != want {
			t.Errorf("PercentDecode(%q) = %q, want %q", in, got, want)
		}
	}
}
