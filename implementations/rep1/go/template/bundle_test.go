package template

import "testing"

func TestParseBundle(t *testing.T) {
	in := "{\"a\":\n 1}\n--\n=== main\nHello {{ a }}!\n=== other\n\nline\n\n=== empty\n=== last\nend\n"
	b, err := ParseBundle([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"main": "Hello {{ a }}!", "other": "\nline\n", "empty": "", "last": "end"}
	for k, v := range want {
		if b.Sources[k] != v {
			t.Errorf("body of %s = %q, want %q", k, b.Sources[k], v)
		}
	}
	if len(b.Names) != 4 || b.Names[0] != "main" || b.Names[3] != "last" {
		t.Errorf("names = %v", b.Names)
	}
	if v, _ := b.Context.Get("a"); v != int64(1) {
		t.Errorf("context a = %v", v)
	}
}

func TestParseBundleNoTrailingNewline(t *testing.T) {
	b, err := ParseBundle([]byte("{}\n--\n=== main\nx"))
	if err != nil || b.Sources["main"] != "x" {
		t.Fatalf("%v %v", b, err)
	}
}

func TestParseBundleErrors(t *testing.T) {
	for _, in := range []string{"{}", "{}\n--\n", "[]\n--\n=== a\nx", "{\n--\n=== a\nx"} {
		if _, err := ParseBundle([]byte(in)); err == nil {
			t.Errorf("ParseBundle(%q) succeeded", in)
		}
	}
}

func TestProcess(t *testing.T) {
	cases := []struct{ in, want string }{
		{"{\"n\": 3}\n--\n=== main\nn={{ n }}\n", "n=3\n"},
		{"{}\n--\n=== main\n", "\n"},
		{"{}\n--\n=== main\n{{ x }}\n", "error: undefined\n"},
		{"{}\n--\n=== main\n{% if %}\n", "error: syntax\n"},
		{"{}\n--\n=== main\n{{ 1|nope }}\n", "error: filter\n"},
		{"{}\n--\n=== main\n{% include 'zz' %}\n", "error: template\n"},
		{"{}\n--\n=== main\n{{ [] + 1 }}\n", "error: type\n"},
	}
	for _, c := range cases {
		got, err := Process([]byte(c.in))
		if err != nil || got != c.want {
			t.Errorf("Process(%q) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
	if _, err := Process([]byte("garbage")); err == nil {
		t.Error("expected error for malformed bundle")
	}
}
