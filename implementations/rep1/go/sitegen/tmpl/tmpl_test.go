package tmpl

import (
	"errors"
	"strings"
	"testing"
)

// testCtx is the root scope used by most tests.
func testCtx() *Dict {
	d := NewDict()
	d.Set("n", 3)
	d.Set("f", 2.5)
	d.Set("s", "Hello")
	d.Set("e", "")
	d.Set("nn", nil)
	d.Set("t", true)
	d.Set("l", List{int64(3), int64(1), int64(2)})
	d.Set("sl", StringList([]string{"b", "A", "c", "B"}))
	dd := NewDict()
	dd.Set("a", 1)
	dd.Set("b", "x")
	dd.Set("c", List{int64(1), int64(2)})
	d.Set("d", dd)
	d.Set("words", "  padded\t\n")
	return d
}

// run renders template "main" (plus extra templates) and returns the output
// or the error kind as "error: kind".
func run(t *testing.T, main string, extra map[string]string) string {
	t.Helper()
	e := New()
	e.Add("main", main)
	for k, v := range extra {
		e.Add(k, v)
	}
	out, err := e.Render("main", testCtx())
	if err != nil {
		var te *Error
		if !errors.As(err, &te) {
			t.Fatalf("unexpected error type %T: %v", err, err)
		}
		return "error: " + te.Kind.String()
	}
	return out
}

func TestExpressions(t *testing.T) {
	tests := []struct{ expr, want string }{
		{"1 + 2", "3"},
		{"1 + 2.5", "3.5"},
		{"7 / 2", "3.5"},
		{"6 / 3", "2.0"},
		{"7 // 2", "3"},
		{"-7 // 2", "-4"},
		{"7.0 // 2", "3.0"},
		{"-7 % 3", "2"},
		{"7 % -3", "-2"},
		{"2 ** 10", "1024"},
		{"2 ** -1", "0.5"},
		{"-2 ** 2", "4"},
		{"2 ** 3 ** 2", "64"},
		{"1 + 2 * 3 - 4 / 2", "5.0"},
		{"'a' ~ 1 ~ 2.5", "a12.5"},
		{"'ab' * 3", "ababab"},
		{"3 * 'ab'", "ababab"},
		{"'ab' * -1", ""},
		{"[1] + [2, 3]", "[1, 2, 3]"},
		{"true + true", "2"},
		{"n == 3.0", "True"},
		{"t == 1", "True"},
		{"'1' == 1", "False"},
		{"nn == nn", "True"},
		{"nn == 0", "False"},
		{"l == [3, 1, 2]", "True"},
		{"1 < 2 < 3", "True"},
		{"3 > 2 > 2", "False"},
		{"'B' < 'a'", "True"},
		{"'ab' < 'abc'", "True"},
		{"3 in l", "True"},
		{"'a' in d", "True"},
		{"'z' in d", "False"},
		{"'ell' in s", "True"},
		{"'' in s", "True"},
		{"2 not in l", "False"},
		{"0 or 'x'", "x"},
		{"'' and 1", ""},
		{"1 and 2", "2"},
		{"not l == l", "False"},
		{"not e", "True"},
		{"l[0]", "3"},
		{"l[-1]", "2"},
		{"s[0]", "H"},
		{"s[-1]", "o"},
		{"d.a", "1"},
		{"d['b']", "x"},
		{"d.c[1]", "2"},
		{"nope|default('dd')", "dd"},
		{"nope is defined", "False"},
		{"n is defined", "True"},
		{"d.zz is not defined", "True"},
		{"s|upper", "HELLO"},
		{"s|lower", "hello"},
		{"words|trim|upper", "PADDED"},
		{"'<a href=\"x\">&\\'</a>'|escape", "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;"},
		{"s|replace('l', 'L')", "HeLLo"},
		{"s|length", "5"},
		{"d|length", "3"},
		{"'42'|int", "42"},
		{"' 12 '|int", "12"},
		{"'3.7'|int", "3"},
		{"'abc'|int", "0"},
		{"'1e3'|int", "1000"},
		{"'-5.9'|int", "-5"},
		{"f|int", "2"},
		{"l|join(', ')", "3, 1, 2"},
		{"d|join('+')", "a+b+c"},
		{"s|join('-')", "H-e-l-l-o"},
		{"l|first", "3"},
		{"l|last", "2"},
		{"s|first", "H"},
		{"d|last", "c"},
		{"l|reverse|join", "213"},
		{"s|reverse", "olleH"},
		{"l|sort|join", "123"},
		{"sl|sort|join", "AbBc"},
		{"[2.5, 1, 3]|sort|join(' ')", "1 2.5 3"},
		{"e|default('x')", ""},
		{"nope|default", ""},
		{"nn|default('x')", "None"},
		{"1.0", "1.0"},
		{"0.1 + 0.2", "0.30000000000000004"},
		{"1000000000000000.0 * 10", "1e+16"},
		{"0.0001 * 1", "0.0001"},
		{"0.00001 * 1", "1e-05"},
		{"3 * 0.5", "1.5"},
		{"-0.0", "-0.0"},
		{"range(3)|join(',')", "0,1,2"},
		{"range(2, 5)|join(',')", "2,3,4"},
		{"range(5, 0, -2)|join(',')", "5,3,1"},
		{"[1, 'a', true, none, 1.5, \"it's\"]", `[1, 'a', True, None, 1.5, "it's"]`},
		{"d", "{'a': 1, 'b': 'x', 'c': [1, 2]}"},
		{"['a\\nb']", `['a\nb']`},
		{"t", "True"},
		{"nn", "None"},
		{"n|int + 1", "4"},
		{"n * s|length", "15"},
		{"-n|int", "-3"},
		{"1 + nope is defined", "1"},
	}
	for _, tc := range tests {
		got := run(t, "{{ "+tc.expr+" }}", nil)
		if got != tc.want {
			t.Errorf("{{ %s }} = %q, want %q", tc.expr, got, tc.want)
		}
	}
}

func TestExpressionErrors(t *testing.T) {
	tests := []struct{ tpl, want string }{
		{"{{ nope }}", "undefined"},
		{"{{ d.zz }}", "undefined"},
		{"{{ d.zz.y }}", "undefined"},
		{"{{ nope.x }}", "undefined"},
		{"{{ nope + 1 }}", "undefined"},
		{"{{ nope == 1 }}", "undefined"},
		{"{{ nope|length }}", "undefined"},
		{"{% if nope %}{% endif %}", "undefined"},
		{"{{ nope and 1 }}", "undefined"},
		{"{% for i in nope %}{% endfor %}", "undefined"},
		{"{{ nope() }}", "undefined"},
		{"{{ loop }}", "undefined"},
		{"{{ super() }}", "undefined"},
		{"{{ 1 + 'a' }}", "type"},
		{"{{ 'a' - 'b' }}", "type"},
		{"{{ 1 < 'a' }}", "type"},
		{"{{ n / 0 }}", "type"},
		{"{{ n // 0 }}", "type"},
		{"{{ n % 0 }}", "type"},
		{"{{ 0 ** -1 }}", "type"},
		{"{{ -s }}", "type"},
		{"{{ n() }}", "type"},
		{"{{ 1 in 'abc' }}", "type"},
		{"{{ 1 in 5 }}", "type"},
		{"{{ n|length }}", "type"},
		{"{{ s|upper(1) }}", "type"},
		{"{{ nope|default(1, 2) }}", "type"},
		{"{{ s|replace('a') }}", "type"},
		{"{{ ['b', 1]|sort }}", "type"},
		{"{{ n|join }}", "type"},
		{"{% for c in n %}{% endfor %}", "type"},
		{"{{ range() }}", "type"},
		{"{{ range(1, 2, 0) }}", "type"},
		{"{{ range('a') }}", "type"},
		{"{{ range(nope) }}", "undefined"},
		{"{{ s|nofilter }}", "filter"},
		{"{% if false %}{{ s|nofilter }}{% endif %}", "filter"},
		{"{{ ( }}", "syntax"},
		{"{{ 1 + }}", "syntax"},
		{"{{ n - }}", "syntax"},
		{"{{ {} }}", "syntax"},
		{"{{ 'a' if n else 'b' }}", "syntax"},
		{"{{ 'bad \\q escape' }}", "syntax"},
		{"{{ 'unterminated }}", "syntax"},
		{"{{ n is odd }}", "syntax"},
		{"{{{ 1 }}}", "syntax"},
		{"{{ 1 }", "syntax"},
		{"{# open", "syntax"},
		{"{% if true %}x", "syntax"},
		{"{% endif %}", "syntax"},
		{"{% for x in l %}{% endif %}", "syntax"},
		{"{% foo %}", "syntax"},
		{"{% %}", "syntax"},
		{"{% raw %}x{% endraw %}", "syntax"},
		{"{% for a, b in l %}{% endfor %}", "syntax"},
		{"{% set a, b = 1, 2 %}", "syntax"},
		{"{% include 'x' ignore missing %}", "syntax"},
		{"{% if true %}{% else %}{% else %}{% endif %}", "syntax"},
		{"{% if true %}{% else %}{% elif true %}{% endif %}", "syntax"},
		{"{% block a %}{% endblock b %}", "syntax"},
		{"{% block a %}{% endblock %}{% block a %}{% endblock %}", "syntax"},
		{"{% if true %}{% extends 'x' %}{% endif %}", "syntax"},
		{"{% extends 'x' %}{% extends 'x' %}", "syntax"},
		{"{% macro m(a, a) %}{% endmacro %}", "syntax"},
		{"{% macro m %}{% endmacro %}", "syntax"},
		{"{{ f(a=1, 2) }}", "syntax"},
		{"{{ f(a=1, a=2) }}", "syntax"},
		{"{{ [1, 2,] }}", "syntax"},
		{"{% include 'nope' %}", "template"},
		{"{% extends 'nope' %}", "template"},
		{"{% include 3 %}", "type"},
		{"{% include nope %}", "undefined"},
		{"{% include 'bad' %}", "syntax"},
	}
	extra := map[string]string{"bad": "{% if %}"}
	for _, tc := range tests {
		got := run(t, tc.tpl, extra)
		if got != "error: "+tc.want {
			t.Errorf("%s = %q, want error: %s", tc.tpl, got, tc.want)
		}
	}
}

func TestStatements(t *testing.T) {
	tests := []struct{ name, tpl, want string }{
		{"set", "{% set x = 5 %}{{ x }}{% set x = x + 1 %}{{ x }}", "56"},
		{"for", "{% for i in l %}{{ i }}{% if not loop.last %},{% endif %}{% endfor %}", "3,1,2"},
		{"loop members", "{% for i in l %}{{ loop.index }}/{{ loop.index0 }}/{{ loop.first }}/{{ loop.last }}/{{ loop.length }};{% endfor %}",
			"1/0/True/False/3;2/1/False/False/3;3/2/False/True/3;"},
		{"for else", "{% for i in [] %}x{% else %}empty{% endfor %}", "empty"},
		{"for else not used", "{% for i in l %}{{ i }}{% else %}no{% endfor %}", "312"},
		{"nested loops", "{% for i in l %}{% for j in l %}{{ loop.index }}{% endfor %}-{{ loop.index }} {% endfor %}", "123-1 123-2 123-3 "},
		{"dict iteration", "{% for k in d %}{{ k }}={{ d[k] }};{% endfor %}", "a=1;b=x;c=[1, 2];"},
		{"string iteration", "{% for c in 'ab' %}[{{ c }}]{% endfor %}", "[a][b]"},
		{"set in loop is local", "{% set y = 1 %}{% for i in l %}{% set y = i %}{{ y }}{% endfor %}{{ y }}", "3121"},
		{"if elif else", "{% if n > 5 %}a{% elif n > 2 %}b{% else %}c{% endif %}", "b"},
		{"truthiness", "{% if l %}a{% endif %}{% if [] %}b{% endif %}{% if 0.0 %}d{% endif %}{% if d %}e{% endif %}", "ae"},
		{"comment", "a{# hidden #}b{#- x -#}  c", "abc"},
		{"whitespace control", "a   {{- 1 -}}   b", "a1b"},
		{"trim block tags", "a\n  {%- if true -%}\n  x\n  {%- endif -%}\n  b", "axb"},
		{"no automatic trim", "a\n{% if true %}\nx\n{% endif %}\nb", "a\n\nx\n\nb"},
		{"braces are text", "{ {{ 1 }} } {x} {", "{ 1 } {x} {"},
		{"string with closer", "{{ '%}' }}{{ \"}}\" }}", "%}}}"},
		{"closer before operator", "{{ n -}}  !", "3!"},
		{"range loop", "{% for i in range(3) %}{{ i }}{% endfor %}", "012"},
	}
	for _, tc := range tests {
		if got := run(t, tc.tpl, nil); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestMacros(t *testing.T) {
	tests := []struct{ name, tpl, want string }{
		{"basic", "{% macro m(a) %}<{{ a }}>{% endmacro %}{{ m(1) }}{{ m(a=2) }}", "<1><2>"},
		{"defaults", "{% macro m(a, b=2) %}{{ a }}{{ b }}{% endmacro %}{{ m(1) }}{{ m(1, 3) }}{{ m(b=5, a=6) }}", "121365"},
		{"default sees earlier params", "{% macro m(a, b=a) %}{{ a }}{{ b }}{% endmacro %}{{ m(1) }}", "11"},
		{"missing arg is undefined", "{% macro m(a) %}{{ a|default('dd') }}{{ a is defined }}{% endmacro %}{{ m() }}", "ddFalse"},
		{"too many args", "{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}", "error: type"},
		{"unknown keyword", "{% macro m(a) %}{% endmacro %}{{ m(c=2) }}", "error: type"},
		{"duplicate binding", "{% macro m(a) %}{% endmacro %}{{ m(1, a=2) }}", "error: type"},
		{"recursion", "{% macro fact(n) %}{% if n <= 1 %}1{% else %}{{ n * fact(n - 1)|int }}{% endif %}{% endmacro %}{{ fact(10) }}", "3628800"},
		{"late binding of defining scope", "{% set k = 10 %}{% macro m() %}{{ k }}{% endmacro %}{% set k = 11 %}{{ m() }}", "11"},
		{"does not see caller locals", "{% macro m() %}{{ y }}{% endmacro %}{% for y in l %}{{ m() }}{% endfor %}", "error: undefined"},
		{"local set is local", "{% macro m(x) %}{% set q = x * 2 %}{{ q }}{% endmacro %}{{ m(4) }}{{ q }}", "error: undefined"},
		{"whitespace kept", "{% macro m() %} x {% endmacro %}[{{ m() }}]", "[ x ]"},
		{"macros call macros", "{% macro a() %}A{{ b() }}{% endmacro %}{% macro b() %}B{% endmacro %}{{ a() }}", "AB"},
	}
	for _, tc := range tests {
		got := run(t, tc.tpl, nil)
		if strings.HasPrefix(tc.want, "error: ") {
			if got != tc.want {
				t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
			}
			continue
		}
		if got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestIncludeAndInheritance(t *testing.T) {
	base := map[string]string{"base": "[{% block b %}base{% endblock %}]"}
	tests := []struct {
		name, tpl string
		extra     map[string]string
		want      string
	}{
		{"include", "{% include 'inc' %}", map[string]string{"inc": "inc:{{ n }}"}, "inc:3"},
		{"include sets are private", "{% include 'inc' %}{{ zz }}", map[string]string{"inc": "{% set zz = 1 %}{{ zz }}"}, "error: undefined"},
		{"include sees includer scope", "{% set loc = 7 %}{% include 'inc' %}", map[string]string{"inc": "{{ loc }}"}, "7"},
		{"include in loop sees loop var", "{% for i in l %}{% include 'inc' %}{% endfor %}", map[string]string{"inc": "[{{ i }}]"}, "[3][1][2]"},
		{"nested includes", "{% include 'a' %}", map[string]string{"a": "a{% include 'b' %}", "b": "b"}, "ab"},
		{"include sees macros of includer", "{% macro m() %}M{% endmacro %}{% include 'inc' %}", map[string]string{"inc": "{{ m() }}"}, "M"},
		{"computed name", "{% include 'a' ~ 'b' %}", map[string]string{"ab": "AB"}, "AB"},
		{"override", "{% extends 'base' %}{% block b %}child{% endblock %}", base, "[child]"},
		{"no override", "{% extends 'base' %}", base, "[base]"},
		{"super", "{% extends 'base' %}{% block b %}{{ super() }}+child{% endblock %}", base, "[base+child]"},
		{"super twice", "{% extends 'base' %}{% block b %}{{ super() }}{{ super() }}{% endblock %}", base, "[basebase]"},
		{"text before extends", "x{% extends 'base' %}y{% block b %}c{% endblock %}z", base, "x[c]"},
		{"three levels", "{% extends 'mid' %}{% block b %}G{{ super() }}{% endblock %}",
			map[string]string{"mid": "{% extends 'base' %}{% block b %}M{{ super() }}{% endblock %}", "base": "[{% block b %}B{% endblock %}]"}, "[GMB]"},
		{"child set visible to parent blocks", "{% extends 'base' %}{% set v = 5 %}{% block b %}{{ v }}{% endblock %}", base, "[5]"},
		{"child macro visible in block", "{% extends 'base' %}{% macro m() %}M{% endmacro %}{% block b %}{{ m() }}{% endblock %}", base, "[M]"},
		{"parent macro visible in child block", "{% extends 'base' %}{% block b %}{{ bm() }}{% endblock %}",
			map[string]string{"base": "{% macro bm() %}BM{% endmacro %}[{% block b %}base{% endblock %}]"}, "[BM]"},
		{"set via macro after extends", "{% extends 'base' %}{% macro m() %}hi{% endmacro %}{% set v = m() %}{% block b %}{{ v }}{% endblock %}", base, "[hi]"},
		{"block never sees loop var", "{% extends 'base' %}{% block b %}{{ i }}{% endblock %}",
			map[string]string{"base": "{% for i in l %}{% block b %}x{% endblock %}{% endfor %}"}, "error: undefined"},
		{"nested blocks", "{% extends 'base' %}{% block inner %}J{% endblock %}",
			map[string]string{"base": "<{% block b %}b[{% block inner %}i{% endblock %}]{% endblock %}>"}, "<b[J]>"},
		{"block without extends", "{% block a %}A{% block b %}B{% endblock %}{% endblock %}", nil, "AB"},
		{"super without parent", "{% block a %}{{ super() }}{% endblock %}", nil, "error: undefined"},
		{"super with args", "{% extends 'base' %}{% block b %}{{ super(1) }}{% endblock %}", base, "error: type"},
		{"unused child block", "{% extends 'base' %}{% block other %}c{% endblock %}", base, "[base]"},
		{"broken parent", "{% extends 'bad' %}", map[string]string{"bad": "{{ ( }}"}, "error: syntax"},
		{"unused broken template", "ok", map[string]string{"bad": "{{ ( }}"}, "ok"},
		{"parent filter error", "{% extends 'bad' %}", map[string]string{"bad": "{{ 1|nofilter }}"}, "error: filter"},
	}
	for _, tc := range tests {
		if got := run(t, tc.tpl, tc.extra); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

// The worked examples of the specification.
func TestSpecExamples(t *testing.T) {
	ctx := NewDict()
	user := NewDict()
	user.Set("name", "Ada")
	user.Set("tags", StringList([]string{"x", "y"}))
	ctx.Set("user", user)
	ctx.Set("n", 3)

	e := New()
	e.Add("main", "Hi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% if n > 2 %}big{% endif %}")
	if _, err := e.Render("main", ctx); err == nil || err.(*Error).Kind != SyntaxError {
		t.Errorf("unclosed for: err = %v", err)
	}

	e = New()
	e.Add("main", "Hi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% endfor -%}\n{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}")
	out, err := e.Render("main", ctx)
	if err != nil || out != "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']" {
		t.Errorf("example 2: %q, %v", out, err)
	}

	ctx = NewDict()
	ctx.Set("title", "T")
	ctx.Set("items", List{int64(3), int64(1), int64(2)})
	e = New()
	e.Add("page", "{% extends \"base\" %}\n{% set count = items|length %}\n{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}")
	e.Add("base", "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}")
	e.Add("footer", "-- {{ title|lower }} {{ missing|default(\"end\") }}")
	out, err = e.Render("page", ctx)
	want := "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"
	if err != nil || out != want {
		t.Errorf("example 3: %q, %v", out, err)
	}

	ctx = NewDict()
	a := NewDict()
	a.Set("b", 1)
	ctx.Set("a", a)
	e = New()
	e.Add("main", "{{ a.b }}{{ a.c.d }}")
	_, err = e.Render("main", ctx)
	if err == nil || err.(*Error).Kind != UndefinedError {
		t.Errorf("example 4: err = %v", err)
	}
}

func TestFormatFloat(t *testing.T) {
	tests := map[float64]string{
		0: "0.0", 3: "3.0", 0.5: "0.5", 1000000000000000: "1000000000000000.0", 0.0001: "0.0001",
		1e16: "1e+16", 1e-5: "1e-05", 1.5e300: "1.5e+300",
		-2.5: "-2.5", 123456.789: "123456.789", 1e15 + 0.5: "1000000000000000.5", 5e-324: "5e-324",
		12345678901234567890: "1.2345678901234567e+19",
	}
	a, b := 0.1, 0.2
	tests[a+b] = "0.30000000000000004"
	for f, want := range tests {
		if got := formatFloat(f); got != want {
			t.Errorf("formatFloat(%v) = %q, want %q", f, got, want)
		}
	}
}

func TestDict(t *testing.T) {
	d := NewDict()
	for i := 0; i < 20; i++ {
		d.Set(string(rune('a'+i)), i)
	}
	d.Set("c", "replaced")
	if d.Len() != 20 {
		t.Errorf("Len = %d", d.Len())
	}
	if v, ok := d.Get("c"); !ok || v != "replaced" {
		t.Errorf("Get(c) = %v, %v", v, ok)
	}
	if v, ok := d.Get("t"); !ok || v != int64(19) {
		t.Errorf("Get(t) = %v (%T), %v", v, v, ok)
	}
	if _, ok := d.Get("zz"); ok {
		t.Error("Get(zz) should miss")
	}
	if keys := d.Keys(); keys[0] != "a" || keys[19] != "t" {
		t.Errorf("keys not in insertion order: %v", keys)
	}
}

func TestEngineCachingAndReplace(t *testing.T) {
	e := New()
	e.Add("main", "v1")
	if out, _ := e.Render("main", nil); out != "v1" {
		t.Errorf("got %q", out)
	}
	e.Add("main", "v2")
	if out, _ := e.Render("main", nil); out != "v2" {
		t.Errorf("after replace got %q", out)
	}
	if !e.Has("main") || e.Has("other") {
		t.Error("Has")
	}
	if _, err := e.Render("other", nil); err == nil {
		t.Error("expected a template error")
	}
	// Errors do not leave partial output.
	e.Add("part", "before {{ nope }}")
	if out, err := e.Render("part", nil); out != "" || err == nil {
		t.Errorf("partial render: %q, %v", out, err)
	}
}

func TestErrorFormatting(t *testing.T) {
	e := New()
	e.Add("main", "{{ nope }}")
	_, err := e.Render("main", nil)
	if err == nil || !strings.Contains(err.Error(), "undefined") {
		t.Errorf("error = %v", err)
	}
	for k, name := range map[ErrorKind]string{SyntaxError: "syntax", FilterError: "filter", UndefinedError: "undefined", TemplateError: "template", TypeError: "type"} {
		if k.String() != name {
			t.Errorf("%d.String() = %q", k, k.String())
		}
	}
}

func TestNormalize(t *testing.T) {
	if Normalize(5) != int64(5) || Normalize(float32(1.5)) != float64(1.5) {
		t.Error("numbers not normalised")
	}
	if l, ok := Normalize([]string{"a"}).(List); !ok || l[0] != "a" {
		t.Error("[]string not converted")
	}
	if !IsUndefined(Undefined) || IsUndefined(nil) {
		t.Error("IsUndefined")
	}
}

func TestLargeLoops(t *testing.T) {
	e := New()
	e.Add("main", "{% macro sq(x) %}{{ x * x }}{% endmacro %}{% for i in range(20000) %}{{ sq(i)|int % 10 }}{% endfor %}")
	out, err := e.Render("main", nil)
	if err != nil || len(out) != 20000 {
		t.Errorf("len = %d, err = %v", len(out), err)
	}
}
