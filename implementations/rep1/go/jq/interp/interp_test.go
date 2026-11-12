package interp

import (
	"errors"
	"testing"

	"example.com/jq/syntax"
	"example.com/jq/value"
)

func compile(t *testing.T, src string) *Program {
	t.Helper()
	ast, err := syntax.Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	p, err := Compile(ast)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCompileErrors(t *testing.T) {
	for _, src := range []string{`nosuch`, `map`, `$undefined`, `length(1)`, `. as $x | $y`} {
		ast, err := syntax.Parse(src)
		if err != nil {
			t.Fatalf("Parse(%q): %v", src, err)
		}
		if _, err := Compile(ast); err == nil {
			t.Errorf("Compile(%q) succeeded, want error", src)
		}
	}
}

func TestYieldErrorStopsAndPropagates(t *testing.T) {
	stop := errors.New("stop")
	p := compile(t, `(1,2,3)?`)
	n := 0
	err := p.Run(nil, func(Value) error {
		n++
		return stop
	})
	if err != stop || n != 1 {
		t.Errorf("err = %v after %d outputs, want stop after 1", err, n)
	}
}

func TestLazyEvaluation(t *testing.T) {
	// The error after the first output must not be raised if the consumer stops.
	p := compile(t, `1, error`)
	stop := errors.New("stop")
	if err := p.Run(nil, func(Value) error { return stop }); err != stop {
		t.Errorf("err = %v", err)
	}
}

func TestRuntimeErrorType(t *testing.T) {
	p := compile(t, `.a`)
	err := p.Run(1.0, func(Value) error { return nil })
	var re *Error
	if !errors.As(err, &re) {
		t.Fatalf("err = %v, want *Error", err)
	}
}

func TestSharedValuesAreNotMutated(t *testing.T) {
	doc, _ := value.ParseString(`{"a":[3,1,2],"b":{"x":1}}`)
	before := value.String(doc)
	for _, src := range []string{`.a | sort`, `.b + {"y":2}`, `.a | reverse`, `.b * {"x":{"z":1}}`, `.a + [4]`, `.a | unique`} {
		if err := compile(t, src).Run(doc, func(Value) error { return nil }); err != nil {
			t.Fatal(err)
		}
	}
	if after := value.String(doc); after != before {
		t.Errorf("input mutated: %s -> %s", before, after)
	}
}
