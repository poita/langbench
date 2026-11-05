package template

import "testing"

func TestExpressions(t *testing.T) {
	runCases(t, []renderCase{
		{name: "text", tpl: "a { b } c", want: "a { b } c"},
		{name: "arith", tpl: "{{ 1 + 2 * 3 }} {{ 7 / 2 }} {{ 7 // 2 }} {{ -7 // 2 }} {{ -7 % 3 }} {{ 7 % -3 }}", want: "7 3.5 3 -4 2 -2"},
		{name: "float floor", tpl: "{{ 7.0 // 2 }} {{ 6 / 3 }}", want: "3.0 2.0"},
		{name: "power", tpl: "{{ 2 ** 10 }} {{ 2 ** -1 }} {{ -2 ** 2 }} {{ 2 ** 3 ** 2 }}", want: "1024 0.5 4 64"},
		{name: "concat", tpl: `{{ "a" ~ 1 ~ 2.5 ~ true ~ none }}`, want: "a12.5TrueNone"},
		{name: "str repeat", tpl: `{{ "ab" * 3 }}{{ 2 * "x" }}[{{ "q" * -1 }}]`, want: "ababab" + "xx[]"},
		{name: "compare chain", tpl: "{{ 1 < 2 < 3 }} {{ 1 < 3 < 2 }} {{ 1 == 1.0 }} {{ true == 1 }} {{ 1 == '1' }}", want: "True False True True False"},
		{name: "and or operands", tpl: `{{ 0 or "x" }} {{ "" and 1 }}| {{ 1 and 2 }} {{ not 0 }}`, want: "x | 2 True"},
		{name: "not precedence", tpl: "{{ not 1 == 2 }}", want: "True"},
		{name: "in", tpl: `{{ "b" in "abc" }} {{ "z" not in "abc" }} {{ 2 in [1, 2] }} {{ "k" in d }} {{ 1 in d }}`, ctx: `{"d":{"k":1}}`, want: "True True True True False"},
		{name: "filter precedence", tpl: `{{ 2 * "3"|int }}`, want: "6"},
		{name: "is defined", tpl: `{{ x is defined }} {{ y is not defined }} {{ 1 + x is defined }}`, ctx: `{"x":1}`, want: "True True 2"},
		{name: "list print", tpl: `{{ [1, 'a', True, None, 1.5, "it's", {} ] }}`, kind: ErrSyntax},
		{name: "list print ok", tpl: `{{ [1, 'a', true, none, 1.5, "it's", d] }}`, ctx: `{"d":{"k":[2.0]}}`, want: `[1, 'a', True, None, 1.5, "it's", {'k': [2.0]}]`},
		{name: "string escapes", tpl: `{{ "a\tb\\n\"" }}`, want: "a\tb\\n\""},
		{name: "subscripts", tpl: `{{ l[0] }}{{ l[-1] }}{{ s[1] }}{{ d["a"] }}{{ d.a }}{{ l[5] is defined }}{{ l.x is defined }}`, ctx: `{"l":[1,2,3],"s":"héllo","d":{"a":"A"}}`, want: "13éAAFalseFalse"},
		{name: "negate string", tpl: `{{ -"4"|int }}`, kind: ErrType},
		{name: "unicode", tpl: `{{ s|length }} {{ s|reverse }} {{ s|first }}{{ s|last }}`, ctx: `{"s":"héllo"}`, want: "5 olléh ho"},
		{name: "floats", tpl: "{{ 0.1 + 0.2 }} {{ 1000000000000000.0 }} {{ 10000000000000000.0 }} {{ 0.0001 }} {{ 0.00001 }} {{ 1.5 * 0 }}", want: "0.30000000000000004 1000000000000000.0 1e+16 0.0001 1e-05 0.0"},
	})
}

func TestExpressionErrors(t *testing.T) {
	runCases(t, []renderCase{
		{name: "undefined print", tpl: "{{ x }}", kind: ErrUndefined},
		{name: "undefined attr", ctx: `{"a":{"b":1}}`, tpl: "{{ a.b }}{{ a.c.d }}", kind: ErrUndefined},
		{name: "undefined truthiness", tpl: "{% if x %}{% endif %}", kind: ErrUndefined},
		{name: "undefined ==", tpl: "{{ x == 1 }}", kind: ErrUndefined},
		{name: "undefined filter", tpl: "{{ x|upper(1) }}", kind: ErrUndefined},
		{name: "default extra arg", tpl: "{{ x|default(1, 2) }}", kind: ErrType},
		{name: "undefined call", tpl: "{{ nope() }}", kind: ErrUndefined},
		{name: "call non-callable", tpl: "{{ (1)() }}", kind: ErrType},
		{name: "arg error wins", tpl: "{{ nope(1/0) }}", kind: ErrType},
		{name: "div zero", tpl: "{{ 1 // 0 }}", kind: ErrType},
		{name: "mod zero", tpl: "{{ 1 % 0 }}", kind: ErrType},
		{name: "str + int", tpl: `{{ "a" + 1 }}`, kind: ErrType},
		{name: "lt mixed", tpl: `{{ 1 < "a" }}`, kind: ErrType},
		{name: "in type", tpl: `{{ 1 in "abc" }}`, kind: ErrType},
		{name: "in number", tpl: `{{ 1 in 2 }}`, kind: ErrType},
		{name: "unknown filter", tpl: "{{ 1|nope }}", kind: ErrFilter},
		{name: "unknown filter unexecuted", tpl: "{% if false %}{{ 1|nope }}{% endif %}", kind: ErrFilter},
		{name: "syntax beats filter", tpl: "{{ 1|nope }}{{", kind: ErrSyntax},
		{name: "filter arity", tpl: "{{ 'a'|replace('a') }}", kind: ErrType},
		{name: "no partial output", tpl: "abc{{ 1 // 0 }}", kind: ErrType},
	})
}

func TestSyntaxErrors(t *testing.T) {
	for _, tpl := range []string{
		"{{ 1 +", "{{ x - }}", "{{{ x }}}", "{% if x %}", "{% endif %}", "{% for a, b in x %}{% endfor %}",
		"{% set a, b = 1 %}", `{% include "x" ignore missing %}`, "{% raw %}", "{% %}", "{# open",
		`{{ "\q" }}`, `{{ "abc }}`, "{{ a if b else c }}", "{{ x is odd }}", "{{ f(a=1, 2) }}", "{{ f(a=1, a=2) }}",
		"{{ [1,] }}", "{{ x|upper( }}", "{% block a %}{% endblock b %}", "{% block a %}{% endblock %}{% block a %}{% endblock %}",
		"{% if true %}{% extends 'x' %}{% endif %}", "{% extends 'x' %}{% extends 'y' %}", "{% macro m(a, a) %}{% endmacro %}",
		"{{ 1 ! 2 }}", "{{ 1 }} {% else %}", "{% for x in y %}{% else %}{% else %}{% endfor %}", "{{ }}", "{{ 1.5.5 }}",
	} {
		t.Run(tpl, func(t *testing.T) {
			if _, kind := render(t, "{}", tpl); kind != ErrSyntax {
				t.Fatalf("kind = %q, want syntax", kind)
			}
		})
	}
}

func TestWhitespaceControl(t *testing.T) {
	runCases(t, []renderCase{
		{name: "strip both", tpl: "a  \n {{- 1 -}} \n  b", want: "a1b"},
		{name: "strip stmt", tpl: "a \n{%- if true -%} \n x {%- endif %} \nb", want: "ax \nb"},
		{name: "comment strip", tpl: "a {#- c -#} b", want: "ab"},
		{name: "comment keep", tpl: "a {# c #} b", want: "a  b"},
		{name: "not across tags", tpl: "{{ 1 }} {{- 2 }}", want: "12"},
		{name: "no trim blocks", tpl: "{% if true %}\nx{% endif %}", want: "\nx"},
		{name: "closer before operator", tpl: "{{ 5 -}}  x", want: "5x"},
		{name: "string with closer", tpl: `{{ "%}" }}{% set a = "}}" %}{{ a }}`, want: "%}}}"},
		{name: "comment ends at first closer", tpl: "{# a #} b #}", want: " b #}"},
	})
}

func TestStatements(t *testing.T) {
	runCases(t, []renderCase{
		{name: "if chain", ctx: `{"n":2}`, tpl: "{% if n == 1 %}a{% elif n == 2 %}b{% else %}c{% endif %}", want: "b"},
		{name: "for loop", ctx: `{"xs":["a","b","c"]}`, tpl: "{% for x in xs %}{{ loop.index }}{{ loop.index0 }}{{ x }}{% if loop.first %}F{% endif %}{% if loop.last %}L{% endif %}{{ loop.length }},{% endfor %}", want: "10aF3,21b3,32cL3,"},
		{name: "for else", tpl: "{% for x in [] %}x{% else %}empty{% endfor %}", want: "empty"},
		{name: "for dict", ctx: `{"d":{"b":1,"a":2}}`, tpl: "{% for k in d %}{{ k }}{% endfor %}", want: "ba"},
		{name: "for string", tpl: `{% for c in "añb" %}[{{ c }}]{% endfor %}`, want: "[a][ñ][b]"},
		{name: "nested loop", tpl: "{% for i in range(2) %}{% for j in range(2) %}{{ loop.index }}{% endfor %}{{ loop.index }}{% endfor %}", want: "121122"},
		{name: "loop undefined outside", tpl: "{{ loop.index }}", kind: ErrUndefined},
		{name: "for non-seq", tpl: "{% for x in 5 %}{% endfor %}", kind: ErrType},
		{name: "set scoping", tpl: "{% set a = 1 %}{% for i in [1] %}{% set a = 2 %}{{ a }}{% endfor %}{{ a }}", want: "21"},
		{name: "range", tpl: "{{ range(3)|join(',') }} {{ range(1, 4)|join(',') }} {{ range(5, 0, -2)|join(',') }} {{ range(0)|length }}", want: "0,1,2 1,2,3 5,3,1 0"},
		{name: "range errors", tpl: "{{ range(1, 2, 0) }}", kind: ErrType},
		{name: "range kw", tpl: "{{ range(stop=1) }}", kind: ErrType},
		{name: "range shadow", ctx: `{"range":[1]}`, tpl: "{{ range[0] }}", want: "1"},
	})
}

func TestMacros(t *testing.T) {
	runCases(t, []renderCase{
		{name: "basic", tpl: "{% macro m(a, b=2) %}{{ a }}-{{ b }}{% endmacro %}{{ m(1) }} {{ m(1, 3) }} {{ m(b=5, a=4) }}", want: "1-2 1-3 4-5"},
		{name: "default refers earlier", tpl: "{% macro m(a, b=a ~ 'x') %}{{ b }}{% endmacro %}{{ m('q') }}", want: "qx"},
		{name: "recursion", tpl: "{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n-1)|int }}{% endif %}{% endmacro %}{{ f(5) }}", want: "120"},
		{name: "missing param undefined", tpl: "{% macro m(a) %}{{ a is defined }}{% endmacro %}{{ m() }}", want: "False"},
		{name: "missing param used", tpl: "{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}", kind: ErrUndefined},
		{name: "too many", tpl: "{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}", kind: ErrType},
		{name: "unknown kw", tpl: "{% macro m(a) %}{% endmacro %}{{ m(b=1) }}", kind: ErrType},
		{name: "kw twice bound", tpl: "{% macro m(a) %}{% endmacro %}{{ m(1, a=2) }}", kind: ErrType},
		{name: "lexical capture", tpl: "{% macro m() %}{{ v }}{% endmacro %}{% set v = 'late' %}{{ m() }}", want: "late"},
		{name: "no caller locals", tpl: "{% macro m() %}{{ v is defined }}{% endmacro %}{% for v in [1] %}{{ m() }}{% endfor %}", want: "False"},
	})
}

func TestIncludeAndInheritance(t *testing.T) {
	t.Run("include scope", func(t *testing.T) {
		got, kind := render(t, `{"a":1}`, `{% set x = 5 %}{% include "inc" %}[{{ y is defined }}]`, "inc", "{{ a }}{{ x }}{% set y = 1 %}")
		if kind != "" || got != "15[False]" {
			t.Fatalf("got %q %q", got, kind)
		}
	})
	t.Run("missing", func(t *testing.T) {
		if _, kind := render(t, "{}", `{% include "nope" %}`); kind != ErrTemplate {
			t.Fatal(kind)
		}
	})
	t.Run("non-string", func(t *testing.T) {
		if _, kind := render(t, "{}", `{% include 3 %}`); kind != ErrType {
			t.Fatal(kind)
		}
		if _, kind := render(t, "{}", `{% include nope %}`); kind != ErrUndefined {
			t.Fatal(kind)
		}
	})
	t.Run("broken included template", func(t *testing.T) {
		if _, kind := render(t, "{}", `ok{% include "b" %}`, "b", "{{"); kind != ErrSyntax {
			t.Fatal(kind)
		}
		if _, kind := render(t, "{}", `ok{% include "b" %}`, "b", "{{ 1|zip }}"); kind != ErrFilter {
			t.Fatal(kind)
		}
		// A template that is never loaded is never checked.
		if got, kind := render(t, "{}", `ok`, "b", "{{"); kind != "" || got != "ok" {
			t.Fatal(got, kind)
		}
	})
	t.Run("worked example", func(t *testing.T) {
		got, kind := render(t, `{"title": "T", "items": [3, 1, 2]}`,
			"{% extends \"base\" %}\n{% set count = items|length %}\n{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}",
			"base", "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}",
			"footer", "-- {{ title|lower }} {{ missing|default(\"end\") }}")
		want := "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"
		if kind != "" || got != want {
			t.Fatalf("got %q (%q), want %q", got, kind, want)
		}
	})
	t.Run("three levels", func(t *testing.T) {
		got, kind := render(t, "{}", `{% extends "b" %}{% block x %}G({{ super() }}){% endblock %}`,
			"b", `{% extends "c" %}{% block x %}B({{ super() }}){% endblock %}`,
			"c", `[{% block x %}C{% endblock %}]`)
		if kind != "" || got != "[G(B(C))]" {
			t.Fatalf("got %q %q", got, kind)
		}
	})
	t.Run("output before extends and suppression", func(t *testing.T) {
		got, kind := render(t, "{}", `pre{% extends "b" %}ignored{{ 1/0 }}{% set v = "S" %}{% block x %}{{ v }}{% endblock %}`,
			"b", `<{% block x %}base{% endblock %}>`)
		if kind != "" || got != "pre<S>" {
			t.Fatalf("got %q %q", got, kind)
		}
	})
	t.Run("super without parent", func(t *testing.T) {
		if _, kind := render(t, "{}", `{% block x %}{{ super() }}{% endblock %}`); kind != ErrUndefined {
			t.Fatal(kind)
		}
		if _, kind := render(t, "{}", `{{ super() }}`); kind != ErrUndefined {
			t.Fatal(kind)
		}
	})
	t.Run("block scope", func(t *testing.T) {
		got, kind := render(t, "{}", `{% for i in [1] %}{% block b %}{{ i is defined }}{% endblock %}{% endfor %}`)
		if kind != "" || got != "False" {
			t.Fatalf("got %q %q", got, kind)
		}
	})
}
