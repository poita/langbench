package syntax

import (
	"strings"
	"testing"

	"example.com/template/tplerr"
	"example.com/template/value"
)

func mustParse(t *testing.T, src string) *Template {
	t.Helper()
	tpl, err := Parse("t", src)
	if err != nil {
		t.Fatalf("Parse(%q): %v", src, err)
	}
	return tpl
}

func TestParseStructure(t *testing.T) {
	tpl := mustParse(t, `a{% if x %}b{% elif y %}c{% else %}d{% endif %}{% for i in l %}{{ i }}{% else %}e{% endfor %}`+
		`{% set v = 1 %}{% macro m(p, q=2) %}{{ p }}{% endmacro %}{% include "x" %}{% block k %}{% block j %}{% endblock j %}{% endblock %}`)
	var kinds []string
	for _, n := range tpl.Body {
		switch n.(type) {
		case *Text:
			kinds = append(kinds, "text")
		case *If:
			kinds = append(kinds, "if")
		case *For:
			kinds = append(kinds, "for")
		case *Set:
			kinds = append(kinds, "set")
		case *MacroDef:
			kinds = append(kinds, "macro")
		case *Include:
			kinds = append(kinds, "include")
		case *Block:
			kinds = append(kinds, "block")
		}
	}
	if got := strings.Join(kinds, " "); got != "text if for set macro include block" {
		t.Errorf("body kinds: %s", got)
	}
	if len(tpl.Blocks) != 2 || tpl.Blocks["j"] == nil || tpl.Blocks["k"] == nil {
		t.Errorf("blocks: %v", tpl.Blocks)
	}
	ifn := tpl.Body[1].(*If)
	if len(ifn.Conds) != 2 || len(ifn.Else) != 1 {
		t.Errorf("if: %+v", ifn)
	}
}

func TestFilterNamesCollected(t *testing.T) {
	tpl := mustParse(t, `{{ a|upper|nope }}{% macro m(x=y|first) %}{% endmacro %}`)
	if got := strings.Join(tpl.Filters, ","); got != "upper,nope,first" {
		t.Errorf("filters: %s", got)
	}
}

// exprShape renders the parse tree of an expression as a fully parenthesised
// string so precedence can be checked.
func exprShape(t *testing.T, src string) string {
	t.Helper()
	tpl := mustParse(t, "{{ "+src+" }}")
	return shape(tpl.Body[0].(*Print).X)
}

func shape(e Expr) string {
	switch e := e.(type) {
	case *Literal:
		return strings.TrimSpace(strings.ReplaceAll(fmtLit(e.Value), "\n", ""))
	case *Name:
		return e.Name
	case *Neg:
		return "(-" + shape(e.X) + ")"
	case *Not:
		return "(not " + shape(e.X) + ")"
	case *Binary:
		return "(" + shape(e.L) + " " + opName[e.Op] + " " + shape(e.R) + ")"
	case *Logic:
		op := "and"
		if e.Or {
			op = "or"
		}
		return "(" + shape(e.L) + " " + op + " " + shape(e.R) + ")"
	case *Compare:
		s := "(" + shape(e.First)
		for i := range e.Ops {
			s += " cmp " + shape(e.Rest[i])
		}
		return s + ")"
	case *FilterExpr:
		s := "(" + shape(e.X) + "|" + e.Name
		for _, a := range e.Args {
			s += " " + shape(a)
		}
		return s + ")"
	case *IsDefined:
		if e.Negate {
			return "(" + shape(e.X) + " is not defined)"
		}
		return "(" + shape(e.X) + " is defined)"
	case *Attr:
		return "(" + shape(e.X) + "." + e.Name + ")"
	case *Index:
		return "(" + shape(e.X) + "[" + shape(e.Key) + "])"
	case *Call:
		s := "(call " + shape(e.Fn)
		for _, a := range e.Args {
			s += " " + shape(a)
		}
		for _, k := range e.Kwargs {
			s += " " + k.Name + "=" + shape(k.X)
		}
		return s + ")"
	case *ListLit:
		s := "[list"
		for _, a := range e.Elems {
			s += " " + shape(a)
		}
		return s + "]"
	}
	return "?"
}

func TestPrecedence(t *testing.T) {
	tests := map[string]string{
		"a * b|int":          "(a * (b|int))",
		"-x|int":             "((-x)|int)",
		"x.y|f":              "((x.y)|f)",
		"1 + x is defined":   "(1 + (x is defined))",
		"not a == b":         "(not (a cmp b))",
		"a < b < c":          "(a cmp b cmp c)",
		"a or b and c":       "(a or (b and c))",
		"a - b ~ c":          "(a - (b ~ c))",
		"2 ** 3 ** 2":        "((2 ** 3) ** 2)",
		"-2 ** 2":            "((-2) ** 2)",
		"2 ** -1":            "(2 ** (-1))",
		"a - b - c":          "((a - b) - c)",
		"a not in b":         "(a cmp b)",
		"x is not defined":   "(x is not defined)",
		"f(1, k=2)(3)":       "(call (call f 1 k=2) 3)",
		"a[0].b[c]":          "(((a[0]).b)[c])",
		"[1, [2]]":           "[list 1 [list 2]]",
		"x|join(', ')|upper": "((x|join ', ')|upper)",
	}
	for src, want := range tests {
		if got := exprShape(t, src); got != want {
			t.Errorf("%s: got %s, want %s", src, got, want)
		}
	}
}

func TestWhitespaceControl(t *testing.T) {
	items, err := lex("a \n {{- x -}} \n b {%- if y -%} \n c {#- note -#} \n d {{ z }}")
	if err != nil {
		t.Fatal(err)
	}
	var texts []string
	for _, it := range items {
		if it.kind == itemText {
			texts = append(texts, it.text)
		}
	}
	if got := strings.Join(texts, "|"); got != "a|b|c|d " {
		t.Errorf("texts: %q", got)
	}
}

func TestLexingEdgeCases(t *testing.T) {
	// A closer inside a string does not end the tag; -}} is a closer, not minus.
	mustParse(t, `{{ "%}" ~ '}}' }}{% set a = "x" %}{{ a -}}`)
	mustParse(t, `{{ "a\\b\"c\'d\n\t" }}`)
	mustParse(t, `{# comment with {{ and {% inside #}x`)
	mustParse(t, `{ } } {not a tag} {`)
	mustParse(t, `{{ 1.5 }}{{ 1 }}{{-1}}`)
}

func TestSyntaxErrors(t *testing.T) {
	bad := []string{
		`{{ x`, `{% if x %}`, `{# x`, `{{{ x }}}`, `{{ }}`, `{{ x - }}`, `{{ "abc }}`, `{{ "\q" }}`, `{{ x @ y }}`,
		`{% if x %}{% endfor %}`, `{% endif %}`, `{% else %}`, `{% elif x %}`, `{% for x in y %}`, `{% for a, b in x %}`,
		`{% for x in y if z %}{% endfor %}`, `{% for x y %}{% endfor %}`, `{% set a, b = 1 %}`, `{% set a %}`,
		`{% set and = 1 %}`, `{% include "x" ignore missing %}`, `{% block x scoped %}{% endblock %}`,
		`{% block a %}{% endblock b %}`, `{% block a %}{% endblock %}{% block a %}{% endblock %}`,
		`{% block a %}{% block a %}{% endblock %}{% endblock %}`, `{% raw %}{% endraw %}`, `{% import "x" %}`, `{%%}`,
		`{% extends "a" %}{% extends "b" %}`, `{% if x %}{% extends "a" %}{% endif %}`, `{% macro m() %}{% extends "a" %}{% endmacro %}`,
		`{% macro m(a, a) %}{% endmacro %}`, `{% macro m(a=1, b) %}{% endmacro %}`, `{% macro m(a,) %}{% endmacro %}`,
		`{% if x %}{% else %}{% else %}{% endif %}`, `{% if x %}{% else %}{% elif y %}{% endif %}`,
		`{{ f(a=1, 2) }}`, `{{ f(a=1, a=2) }}`, `{{ f(1,) }}`, `{{ [1,] }}`, `{{ x is odd }}`, `{{ x|upper(1,) }}`,
		`{{ a if b else c }}`, `{{ {"a": 1} }}`, `{{ a[1:2] }}`, `{{ (1, 2) }}`, `{{ x.0 }}`, `{{ not }}`, `{{ and }}`,
		`{% endfor extra %}`, `{% if x extra %}{% endif %}`, `{{ x }} {{ y z }}`, `{{ 99999999999999999999 }}`,
	}
	for _, src := range bad {
		_, err := Parse("t", src)
		if k, _ := tplerr.KindOf(err); k != tplerr.Syntax {
			t.Errorf("Parse(%q): got %v, want a syntax error", src, err)
		}
	}
}

var opName = map[value.Op]string{
	value.OpAdd: "+", value.OpSub: "-", value.OpMul: "*", value.OpDiv: "/",
	value.OpFloorDiv: "//", value.OpMod: "%", value.OpPow: "**", value.OpConcat: "~",
}

func fmtLit(v value.Value) string {
	s, _ := value.Repr(v)
	return s
}
