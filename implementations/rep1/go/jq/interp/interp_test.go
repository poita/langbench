package interp_test

import (
	"testing"

	"github.com/peter/jq/interp"
	"github.com/peter/jq/syntax"
	"github.com/peter/jq/value"
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

func TestVariableScoping(t *testing.T) {
	// $x inside reduce's update refers to the reduce variable, and the outer
	// binding is visible again afterwards.
	p := compile(t, `1 as $x | (reduce (10,20) as $x (0; . + $x)), $x`)
	var got []string
	if err := p.Run(value.Null, func(v value.Value) error {
		got = append(got, value.JSON(v))
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != "30" || got[1] != "1" {
		t.Errorf("got %v", got)
	}
}

func TestCompileUndefined(t *testing.T) {
	ast, _ := syntax.Parse(`$nope`)
	if _, err := interp.Compile(ast); err == nil {
		t.Error("expected undefined variable error")
	}
	ast, _ = syntax.Parse(`frobnicate(1)`)
	if _, err := interp.Compile(ast); err == nil {
		t.Error("expected undefined builtin error")
	}
}

func TestErrorPayload(t *testing.T) {
	p := compile(t, `error({"a":1})`)
	err := p.Run(value.Null, func(value.Value) error { return nil })
	re, ok := err.(*interp.Error)
	if !ok || value.JSON(re.Value) != `{"a":1}` {
		t.Errorf("got %#v", err)
	}
}

func TestProgramIsReusable(t *testing.T) {
	p := compile(t, `{a: (1,2)}`)
	for i := 0; i < 3; i++ {
		n := 0
		_ = p.Run(value.Null, func(value.Value) error { n++; return nil })
		if n != 2 {
			t.Fatalf("run %d produced %d outputs", i, n)
		}
	}
}
