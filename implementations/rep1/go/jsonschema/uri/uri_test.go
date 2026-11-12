package uri

import "testing"

// Examples from RFC 3986 section 5.4.
func TestResolveRFC3986(t *testing.T) {
	const base = "http://a/b/c/d;p?q"
	tests := []struct{ ref, want string }{
		// 5.4.1 normal examples
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
		// 5.4.2 abnormal examples
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
		{"http:g", "http:g"}, // strict resolution keeps the scheme
	}
	for _, tc := range tests {
		if got := ResolveString(base, tc.ref); got != tc.want {
			t.Errorf("Resolve(%q, %q) = %q, want %q", base, tc.ref, got, tc.want)
		}
	}
}

func TestResolveSpecialBases(t *testing.T) {
	tests := []struct{ base, ref, want string }{
		{"", "#/$defs/a", "#/$defs/a"},
		{"", "integer.json", "integer.json"},
		{"", "", ""},
		{"http://x.test", "a", "http://x.test/a"},
		{"urn:example:root", "#foo", "urn:example:root#foo"},
		{"http://x.test/a/b.json", "../c.json#f", "http://x.test/c.json#f"},
		{"http://x.test/a/b.json#old", "#new", "http://x.test/a/b.json#new"},
	}
	for _, tc := range tests {
		if got := ResolveString(tc.base, tc.ref); got != tc.want {
			t.Errorf("Resolve(%q, %q) = %q, want %q", tc.base, tc.ref, got, tc.want)
		}
	}
}

func TestParseComponents(t *testing.T) {
	u := Parse("http://user@host:80/p/a?q=1#frag")
	if u.Scheme != "http" || u.Authority != "user@host:80" || u.Path != "/p/a" || u.Query != "q=1" || u.Fragment != "frag" {
		t.Errorf("unexpected components: %+v", u)
	}
	if got := u.String(); got != "http://user@host:80/p/a?q=1#frag" {
		t.Errorf("String() = %q", got)
	}
	if u := Parse("a?"); !u.HasQuery || u.Query != "" || u.String() != "a?" {
		t.Errorf("empty query lost: %+v", u)
	}
	if u := Parse("a#"); !u.HasFragment || u.String() != "a#" {
		t.Errorf("empty fragment lost: %+v", u)
	}
	if u := Parse("a/b:c"); u.HasScheme {
		t.Errorf("a/b:c has no scheme: %+v", u)
	}
	if u := Parse("1http://x"); u.HasScheme {
		t.Errorf("scheme cannot start with a digit: %+v", u)
	}
	if got := Parse("http://x/y#f").WithoutFragment().String(); got != "http://x/y" {
		t.Errorf("WithoutFragment = %q", got)
	}
}

func TestPercentDecode(t *testing.T) {
	tests := map[string]string{
		"plain":        "plain",
		"a%20b":        "a b",
		"%25":          "%",
		"%C3%A9":       "é",
		"%zz":          "%zz",
		"%2":           "%2",
		"100%":         "100%",
		"%7Efoo%2fbar": "~foo/bar",
	}
	for in, want := range tests {
		if got := PercentDecode(in); got != want {
			t.Errorf("PercentDecode(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRemoveDotSegments(t *testing.T) {
	tests := map[string]string{
		"/a/b/c/./../../g":   "/a/g",
		"mid/content=5/../6": "mid/6",
		"/a/b/..":            "/a/",
		"a/./b":              "a/b",
		"../x":               "x",
		"/..":                "/",
		"":                   "",
	}
	for in, want := range tests {
		if got := RemoveDotSegments(in); got != want {
			t.Errorf("RemoveDotSegments(%q) = %q, want %q", in, got, want)
		}
	}
}
