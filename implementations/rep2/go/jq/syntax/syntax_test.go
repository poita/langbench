package syntax_test

import (
	"testing"

	"example.com/jq/syntax"
)

func parse(t *testing.T, src string) syntax.Node {
	t.Helper()
	n, err := syntax.Parse(src)
	if err != nil {
		t.Fatalf("parse %q: %v", src, err)
	}
	return n
}

func TestPrecedence(t *testing.T) {
	// a | b, c  is  a | (b, c)
	p, ok := parse(t, `1 | 2, 3`).(*syntax.Pipe)
	if !ok {
		t.Fatal("expected pipe at top")
	}
	if _, ok := p.R.(*syntax.Comma); !ok {
		t.Errorf("right side of pipe should be a comma, got %T", p.R)
	}
	// 1, 2 | f  is  (1, 2) | f
	if p, ok := parse(t, `1, 2 | length`).(*syntax.Pipe); !ok {
		t.Error("expected pipe")
	} else if _, ok := p.L.(*syntax.Comma); !ok {
		t.Errorf("left side should be a comma, got %T", p.L)
	}
	// 1 + 2 * 3
	b := parse(t, `1 + 2 * 3`).(*syntax.Binary)
	if b.Op != syntax.OpAdd {
		t.Error("top operator should be +")
	}
	if m, ok := b.R.(*syntax.Binary); !ok || m.Op != syntax.OpMul {
		t.Error("right operand should be a multiplication")
	}
	// 1 - 1 vs 1 - -1 and "1 -1"
	if b := parse(t, `1 -1`).(*syntax.Binary); b.Op != syntax.OpSub {
		t.Error("1 -1 is subtraction")
	}
	if _, ok := parse(t, `a or b and c`).(*syntax.Call); ok {
		t.Error("should parse as or")
	}
	if o, ok := parse(t, `true or false and null`).(*syntax.Or); !ok {
		t.Error("expected or")
	} else if _, ok := o.R.(*syntax.And); !ok {
		t.Error("and binds tighter than or")
	}
}

func TestOptionalMeanings(t *testing.T) {
	if i, ok := parse(t, `.a?`).(*syntax.Index); !ok || !i.Opt {
		t.Error(".a? should be an optional index")
	}
	// .a.b? : only the last operation is optional
	i := parse(t, `.a.b?`).(*syntax.Index)
	if !i.Opt || i.Term.(*syntax.Index).Opt {
		t.Error("only .b should be optional")
	}
	if _, ok := parse(t, `(.a)?`).(*syntax.Try); !ok {
		t.Error("(.a)? should be try")
	}
	// .a?? : optional index wrapped in try
	if tr, ok := parse(t, `.a??`).(*syntax.Try); !ok {
		t.Error(".a?? should be try")
	} else if !tr.Term.(*syntax.Index).Opt {
		t.Error("inner should stay optional")
	}
	if it, ok := parse(t, `.[]?`).(*syntax.Iterate); !ok || !it.Opt {
		t.Error(".[]? should be optional iterate")
	}
	if s, ok := parse(t, `.[1:]?`).(*syntax.Slice); !ok || !s.Opt || s.To != nil {
		t.Error(".[1:]? should be optional slice")
	}
}

func TestBindingAndReduce(t *testing.T) {
	a, ok := parse(t, `.a as $x | $x + 1`).(*syntax.As)
	if !ok || a.Name != "x" {
		t.Fatal("expected binding")
	}
	if _, ok := a.Body.(*syntax.Binary); !ok {
		t.Error("body should extend to the end")
	}
	r, ok := parse(t, `reduce .[] as $o ({}; . + {($o.k): $o.v})`).(*syntax.Reduce)
	if !ok || r.Name != "o" {
		t.Fatal("expected reduce")
	}
	if _, ok := parse(t, `f | .[] as $x | $x`).(*syntax.Pipe); !ok {
		t.Error("binding after a pipe")
	}
}

func TestObjectForms(t *testing.T) {
	o := parse(t, `{a, "b", $c, d: 1 | 2, (.k): -1, "e f": .x}`).(*syntax.Object)
	if len(o.Entries) != 6 {
		t.Fatalf("got %d entries", len(o.Entries))
	}
	if o.DistinctLiteralKeys {
		t.Error("computed key means keys are not all literal")
	}
	if _, ok := o.Entries[4].Key.(*syntax.Literal); ok {
		t.Error("computed key should not be a literal")
	}
	if _, ok := o.Entries[3].Val.(*syntax.Pipe); !ok {
		t.Error("value should be a pipe of terms")
	}
	if !parse(t, `{a:1,b:2}`).(*syntax.Object).DistinctLiteralKeys {
		t.Error("distinct literal keys")
	}
	if parse(t, `{a:1,a:2}`).(*syntax.Object).DistinctLiteralKeys {
		t.Error("repeated key is not distinct")
	}
}

func TestIfAndStrings(t *testing.T) {
	n := parse(t, `if .a then 1 elif .b then 2 else 3 end`).(*syntax.If)
	if e, ok := n.Else.(*syntax.If); !ok || e.Else == nil {
		t.Error("elif should nest an if with its own else")
	}
	if parse(t, `if . then 1 end`).(*syntax.If).Else != nil {
		t.Error("missing else should be nil")
	}
	l := parse(t, `"a\né😀\/"`).(*syntax.Literal)
	if l.Val.Str() != "a\né😀/" {
		t.Errorf("decoded %q", l.Val.Str())
	}
}

func TestErrors(t *testing.T) {
	for _, src := range []string{``, `.[`, `1 +`, `{a:}`, `if 1 then 2`, `"abc`, `$`, `@`, `reduce . as $x (1)`, `. as x | 1`} {
		if _, err := syntax.Parse(src); err == nil {
			t.Errorf("%q should fail to parse", src)
		}
	}
}
