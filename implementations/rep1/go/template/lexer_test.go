package template

import "testing"

func TestLexItems(t *testing.T) {
	items := lex("a {{ x }} b{% if y %}c{# note #}d")
	kinds := []itemKind{itText, itPrint, itText, itStmt, itText, itText}
	if len(items) != len(kinds) {
		t.Fatalf("got %d items: %+v", len(items), items)
	}
	for i, k := range kinds {
		if items[i].kind != k {
			t.Errorf("item %d kind = %v, want %v", i, items[i].kind, k)
		}
	}
}

func TestLexTokens(t *testing.T) {
	items := lex(`{{ a.b|f(1, 2.5, "s\n") ** -x // 3 != y }}`)
	var got []string
	for _, tk := range items[0].toks {
		switch tk.kind {
		case tkInt:
			got = append(got, "int")
		case tkFloat:
			got = append(got, "float")
		case tkString:
			got = append(got, "str:"+tk.s)
		default:
			got = append(got, tk.s)
		}
	}
	want := []string{"a", ".", "b", "|", "f", "(", "int", ",", "float", ",", "str:s\n", ")", "**", "-", "x", "//", "int", "!=", "y"}
	if len(got) != len(want) {
		t.Fatalf("tokens = %q", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("tokens = %q", got)
		}
	}
}

func TestLexErrors(t *testing.T) {
	for _, src := range []string{"{{ x", "{% x", "{# x", "{{ 'a }}", "{{ @ }}", `{{ "\z" }}`} {
		func() {
			defer func() {
				e, ok := recover().(*Error)
				if !ok || e.Kind != ErrSyntax {
					t.Errorf("lex(%q): want syntax error, got %v", src, e)
				}
			}()
			lex(src)
		}()
	}
}
