package batch

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func run(t testing.TB, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run([]byte(in), &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestWorkedExample(t *testing.T) {
	in := `message Inner { sint32 v = 1; }
message Outer {
  int32 a = 1;
  string b = 2;
  repeated int32 c = 3;
  Inner d = 4;
}
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
encode Outer {d: {}, c: [], a: 0}
decode Outer 3800
decode Outer 08ff
`
	want := "08011201781a02010222020809\n" +
		"{a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n" +
		"2200\n{}\nerror\n"
	if got := run(t, in); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestRequestForms(t *testing.T) {
	schema := "message M { int32 a = 1; }\n--\n"
	tests := []struct{ req, want string }{
		{"decode M", "{}"},
		{"decode M ", "error"},
		{"decode M 0", "error"},
		{"decode M 08G1", "error"},
		{"decode M 0801", "{a: 1}"},
		{"decode M 08FF", "error"},
		{"decode M 0801 ", "error"},
		{"decode M 0801 08", "error"},
		{"decode Nope 0801", "error"},
		{"encode M", "error"},
		{"encode M ", "error"},
		{"encode M    ", "error"},
		{"encode M {}", ""},
		{"encode M  {a: 1}  ", "0801"},
		{"frobnicate M {}", "error"},
	}
	for _, tc := range tests {
		if got := run(t, schema+tc.req); got != tc.want+"\n" {
			t.Errorf("%q: got %q, want %q", tc.req, got, tc.want)
		}
	}
}

func TestNoTrailingNewlineAndNoRequests(t *testing.T) {
	if got := run(t, "message M { int32 a = 1; }\n--"); got != "" {
		t.Errorf("no requests: got %q", got)
	}
	if got := run(t, "message M { int32 a = 1; }\n--\ndecode M 0801\ndecode M 0802"); got != "{a: 1}\n{a: 2}\n" {
		t.Errorf("got %q", got)
	}
}

func TestSchemaStyles(t *testing.T) {
	in := "message A{int32 x=1;B b=2;}message B{\n\trepeated\tint32\r\n y = 1 ;\n}\n--\n" +
		"encode A {b: {y: [1]}, x: 2}\n"
	if got := run(t, in); got != "08021203"+"0a0101\n" {
		t.Errorf("got %q", got)
	}
}

func TestManyRequests(t *testing.T) {
	var in strings.Builder
	in.WriteString("message M { int32 a = 1; }\n--\n")
	var want strings.Builder
	for i := 0; i < 20000; i++ {
		in.WriteString("decode M 0801\n")
		want.WriteString("{a: 1}\n")
	}
	if got := run(t, in.String()); got != want.String() {
		t.Error("output mismatch for many requests")
	}
}

// TestProblemSuite runs the repository's example tests when they are present
// (they live outside this module, so the test is skipped otherwise).
func TestProblemSuite(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "problems", "protowire", "tests")
	ins, _ := filepath.Glob(filepath.Join(dir, "*.in"))
	if len(ins) == 0 {
		t.Skip("problem test suite not found")
	}
	for _, in := range ins {
		name := strings.TrimSuffix(filepath.Base(in), ".in")
		t.Run(name, func(t *testing.T) {
			input, err := os.ReadFile(in)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			if got := run(t, string(input)); strings.TrimRight(got, "\n") != strings.TrimRight(string(want), "\n") {
				t.Error("output differs from expected")
			}
		})
	}
}
