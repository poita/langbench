package depresolve

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func solve(t *testing.T, input string) (string, error) {
	t.Helper()
	reg, root, err := ParseString(input)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	res, err := reg.Resolve(root)
	if err != nil {
		return "", err
	}
	return res.Format(), nil
}

func TestSpecExamples(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"diamond", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n",
			"a 1.0.0\nb 1.0.0\nc 1.2.5\n"},
		{"first-not-newest", "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.5\n"},
		{"order1", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.0\nc 2.0.0\n"},
		{"order2", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: b *, a *\n",
			"a 1.0.0\nb 2.0.0\nc 1.0.0\n"},
		{"empty-root", "a 1.0.0:\nroot:\n", ""},
		{"only-root", "root:\n", ""},
		{"cycle", "a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n", "a 1.0.0\nb 1.0.0\n"},
		{"self-require", "a 1.0.0: a ^1.0.0\nroot: a *\n", "a 1.0.0\n"},
		{"numeric-order", "a 1.9.0:\na 1.10.0:\nroot: a *\n", "a 1.10.0\n"},
		{"name-order", "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n",
			"my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n"},
		{"unrelated-backtrack", // chronological: x is retried although unrelated to the failure
			"x 2.0.0:\nx 1.0.0:\ny 1.0.0: z ^2.0.0\nz 1.0.0:\nroot: x *, y *\n", "unsat"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := solve(t, tc.in)
			if tc.want == "unsat" {
				if !errors.Is(err, ErrUnsatisfiable) {
					t.Fatalf("want unsatisfiable, got %q, %v", got, err)
				}
				return
			}
			if err != nil || got != tc.want {
				t.Fatalf("got %q, %v; want %q", got, err, tc.want)
			}
		})
	}
}

func TestUnsatisfiable(t *testing.T) {
	cases := map[string]string{
		"conflict":      "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n",
		"missing-pkg":   "root: ghost *\n",
		"missing-dep":   "a 1.0.0: ghost *\nroot: a *\n",
		"no-version":    "a 1.0.0:\nroot: a ^2.0.0\n",
		"empty-range":   "a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n",
		"late-conflict": "a 1.0.0:\na 2.0.0:\nroot: a *, a 3.0.0\n",
	}
	for name, in := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := solve(t, in); !errors.Is(err, ErrUnsatisfiable) {
				t.Fatalf("want ErrUnsatisfiable, got %v", err)
			}
		})
	}
}

func TestBacktrackSteppingDownVersions(t *testing.T) {
	var b strings.Builder
	for i := 1; i <= 200; i++ {
		fmt.Fprintf(&b, "lib 1.%d.0:\n", i)
	}
	b.WriteString("root: lib *, lib <=1.3.0\n")
	got, err := solve(t, b.String())
	if err != nil || got != "lib 1.3.0\n" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestDeepChain(t *testing.T) {
	const n = 20000
	var b strings.Builder
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "p%d 1.0.0: p%d *\n", i, i+1)
	}
	fmt.Fprintf(&b, "p%d 1.0.0:\nroot: p0 *\n", n)
	reg, root, err := ParseString(b.String())
	if err != nil {
		t.Fatal(err)
	}
	res, err := reg.Resolve(root)
	if err != nil || len(res) != n+1 {
		t.Fatalf("len=%d err=%v", len(res), err)
	}
}

func TestRegistryReuseAndAdd(t *testing.T) {
	reg := NewRegistry()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(reg.Add("a", Version{1, 0, 0}, nil))
	root := []Requirement{{"a", AnyVersion}}
	res, err := reg.Resolve(root)
	if err != nil || res.Format() != "a 1.0.0\n" {
		t.Fatalf("%v %v", res, err)
	}
	must(reg.Add("a", Version{2, 0, 0}, nil)) // invalidates compiled index
	res, _ = reg.Resolve(root)
	if res.Format() != "a 2.0.0\n" {
		t.Fatalf("after Add: %v", res)
	}
	if err := reg.Add("a", Version{2, 0, 0}, nil); err == nil {
		t.Error("duplicate Add accepted")
	}
	if reg.Len() != 2 {
		t.Errorf("Len = %d", reg.Len())
	}
}

func TestParseErrors(t *testing.T) {
	for _, bad := range []string{
		"", "a 1.0.0:\n", "a 1.0.0 c\nroot:\n", "a 1.0.0: b\nroot:\n",
		"a 1.0.0:b *\nroot:\n", "root:\na 1.0.0:\n", "a x:\nroot:\n",
		"a 1.0.0:\na 1.0.0:\nroot:\n", "a 1.0.0: b ^1\nroot:\n",
	} {
		if _, _, err := ParseString(bad); err == nil {
			t.Errorf("ParseString(%q) succeeded", bad)
		}
	}
}
