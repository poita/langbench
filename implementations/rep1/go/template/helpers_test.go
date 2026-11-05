package template

import (
	"errors"
	"testing"
)

// render renders the main template (with the given extra templates and a
// JSON context) and returns the output or the error kind.
func render(t *testing.T, ctxJSON string, main string, others ...string) (string, ErrorKind) {
	t.Helper()
	src := map[string]string{"main": main}
	for i := 0; i+1 < len(others); i += 2 {
		src[others[i]] = others[i+1]
	}
	v, err := ParseJSON([]byte(ctxJSON))
	if err != nil {
		t.Fatalf("bad context %q: %v", ctxJSON, err)
	}
	out, err := NewEngine(src).Render("main", v.(*Dict))
	if err != nil {
		var te *Error
		if !errors.As(err, &te) {
			t.Fatalf("non-template error: %v", err)
		}
		return "", te.Kind
	}
	return out, ""
}

type renderCase struct {
	name string
	ctx  string
	tpl  string
	want string
	kind ErrorKind // expected error kind, "" for success
}

func runCases(t *testing.T, cases []renderCase) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ctx := c.ctx
			if ctx == "" {
				ctx = "{}"
			}
			got, kind := render(t, ctx, c.tpl)
			if kind != c.kind {
				t.Fatalf("error kind = %q, want %q (output %q)", kind, c.kind, got)
			}
			if kind == "" && got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}
