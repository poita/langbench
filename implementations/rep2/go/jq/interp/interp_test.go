package interp_test

import (
	"testing"

	"example.com/jq/interp"
	"example.com/jq/jsonio"
	"example.com/jq/syntax"
	"example.com/jq/value"
)

func compile(t *testing.T, src string) *interp.Program {
	t.Helper()
	ast, err := syntax.Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	p, err := interp.Compile(ast)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func collect(t *testing.T, src, doc string) (string, error) {
	t.Helper()
	in, err := jsonio.ParseString(doc)
	if err != nil {
		t.Fatal(err)
	}
	var out []byte
	err = compile(t, src).Run(in, func(v value.Value) error {
		out = jsonio.Append(out, v)
		out = append(out, ' ')
		return nil
	})
	return string(out), err
}

func TestSpecExamples(t *testing.T) {
	got, err := collect(t,
		`reduce .[] as $o ({}; . + {($o.k): $o.v}), (map(.v) | add), sort_by(.k, -.v), (group_by(.k) | map([.[0].k, length])), (.[0] | keys), (.[2].v / 4)`,
		`[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]`)
	want := `{"b":3,"a":2} 6 [{"k":"a","v":2},{"k":"b","v":3},{"k":"b","v":1}] [["a",1],["b",2]] ["k","v"] 0.75 `
	if err != nil || got != want {
		t.Errorf("got %q (%v)", got, err)
	}

	got, err = collect(t, `[(1,2) + (10,20)], {a:(1,2), b:(3,4)}, [.[] | .a?], (.[] | .a.b?)`, `[{"a":{"b":1}},{"a":5},3]`)
	want = `[11,12,21,22] {"a":1,"b":3} {"a":1,"b":4} {"a":2,"b":3} {"a":2,"b":4} [{"b":1},5] 1 `
	if got != want {
		t.Errorf("got %q", got)
	}
	if _, ok := err.(*value.Error); !ok {
		t.Errorf("expected a *value.Error, got %v", err)
	}
}

func TestSortStabilityLarge(t *testing.T) {
	doc := "["
	for i := 0; i < 500; i++ {
		if i > 0 {
			doc += ","
		}
		doc += `{"k":` + string(rune('0'+i%3)) + `,"i":` + itoa(i) + `}`
	}
	doc += "]"
	got, err := collect(t, `sort_by(.k) | map(.i) | [.[0], .[1], .[166], .[167]]`, doc)
	if err != nil || got != "[0,3,498,1] " {
		t.Errorf("got %q %v", got, err)
	}
}

func itoa(i int) string { return jsonio.Marshal(value.Number(float64(i))) }

func TestCompileChecks(t *testing.T) {
	for _, src := range []string{`foo`, `$x`, `length(.)`, `select`} {
		ast, err := syntax.Parse(src)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := interp.Compile(ast); err == nil {
			t.Errorf("%q should fail to compile", src)
		}
	}
}
