package tmpl

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// decodeOrdered decodes JSON into template values, keeping object key order.
func decodeOrdered(t *testing.T, dec *json.Decoder) Value {
	t.Helper()
	tok, err := dec.Token()
	if err != nil {
		t.Fatal(err)
	}
	switch v := tok.(type) {
	case json.Delim:
		switch v {
		case '{':
			d := NewDict(0)
			for dec.More() {
				k, _ := dec.Token()
				d.Set(k.(string), decodeOrdered(t, dec))
			}
			dec.Token()
			return d
		case '[':
			l := []Value{}
			for dec.More() {
				l = append(l, decodeOrdered(t, dec))
			}
			dec.Token()
			return l
		}
	case json.Number:
		if i, err := v.Int64(); err == nil && !strings.ContainsAny(v.String(), ".eE") {
			return i
		}
		f, _ := v.Float64()
		return f
	case nil:
		return None
	}
	return tok
}

// run executes a case in the layout "JSON context, a line --, then templates
// introduced by === name lines" and returns the output or "error: <kind>".
func run(t *testing.T, input string) string {
	t.Helper()
	ctxSrc, rest, ok := strings.Cut(input, "\n--\n")
	if !ok {
		t.Fatal("missing -- line")
	}
	dec := json.NewDecoder(strings.NewReader(ctxSrc))
	dec.UseNumber()
	ctx := decodeOrdered(t, dec).(*Dict)
	vars := map[string]Value{}
	for _, k := range ctx.Keys() {
		vars[k], _ = ctx.Get(k)
	}
	set := NewSet()
	first := ""
	parts := strings.Split("\n"+strings.TrimSuffix(rest, "\n"), "\n=== ")
	for _, p := range parts[1:] {
		name, body, _ := strings.Cut(p, "\n")
		if first == "" {
			first = name
		}
		set.Add(name, body)
	}
	out, err := set.Render(first, vars)
	if err != nil {
		var te *Error
		if !errors.As(err, &te) {
			t.Fatalf("unexpected error type %T: %v", err, err)
		}
		return "error: " + te.Kind.String()
	}
	return out
}

func TestSpecExamples(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"unclosed for", `{"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3}
--
=== main
Hi {{ user.name|upper }}!
{% for t in user.tags -%}
  {{ loop.index }}. {{ t }}
{% if n > 2 %}big{% endif %}
`, "error: syntax"},
		{"loop and arithmetic", `{"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3}
--
=== main
Hi {{ user.name|upper }}!
{% for t in user.tags -%}
  {{ loop.index }}. {{ t }}
{% endfor -%}
{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, "s"] }}
`, "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']"},
		{"inheritance", `{"title": "T", "items": [3, 1, 2]}
--
=== page
{% extends "base" %}
{% set count = items|length %}
{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}
=== base
{% macro item(v) %}#{{ v }}{% endmacro -%}
<h1>{% block title %}{{ title }}{% endblock %}</h1>
{% block body %}{{ count }} items{% endblock %}
{% include "footer" %}
=== footer
-- {{ title|lower }} {{ missing|default("end") }}
`, "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"},
		{"undefined attribute", `{"a": {"b": 1}}
--
=== main
{{ a.b }}{{ a.c.d }}
`, "error: undefined"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.in); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

// expr checks the value of a single expression against a context.
func TestExpressions(t *testing.T) {
	tests := []struct{ expr, want string }{
		// Arithmetic and printing.
		{`1 + 2`, "3"},
		{`7 / 2`, "3.5"},
		{`6 / 3`, "2.0"},
		{`7 // 2`, "3"},
		{`-7 // 2`, "-4"},
		{`7.0 // 2`, "3.0"},
		{`-7 % 3`, "2"},
		{`7 % -3`, "-2"},
		{`2 ** 10`, "1024"},
		{`2 ** -1`, "0.5"},
		{`-2 ** 2`, "4"},
		{`2 ** 3 ** 2`, "64"},
		{`1 + 2 * 3`, "7"},
		{`(1 + 2) * 3`, "9"},
		{`1.5 + 1`, "2.5"},
		{`0.1 + 0.2`, "0.30000000000000004"},
		{`1000000000000000.0 * 10`, "1e+16"},
		{`0.0001`, "0.0001"},
		{`0.00001`, "1e-05"},
		{`10.0 ** 300 * 1.5`, "1.5e+300"},
		{`3.0`, "3.0"},
		{`true + true`, "2"},
		{`"ab" * 3`, "ababab"},
		{`3 * "ab"`, "ababab"},
		{`"ab" * -1`, ""},
		{`"a" + "b"`, "ab"},
		{`[1] + [2, 3]`, "[1, 2, 3]"},
		{`"x" ~ 1 ~ true ~ none`, "x1TrueNone"},
		{`1 + 2 ~ 3`, "33"}, // ~ binds tighter than +: 1 + (2 ~ 3) is a type error
		// Booleans and logic.
		{`true`, "True"},
		{`not true`, "False"},
		{`not 1 == 2`, "True"},
		{`0 or "x"`, "x"},
		{`"" and 1`, ""},
		{`1 and 2`, "2"},
		{`none or 0 or []`, "[]"},
		{`1 < 2 < 3`, "True"},
		{`1 < 3 < 2`, "False"},
		{`1 == 1.0`, "True"},
		{`true == 1`, "True"},
		{`1 == "1"`, "False"},
		{`none == 0`, "False"},
		{`[1, 2] == [1, 2.0]`, "True"},
		{`"abc" < "abd"`, "True"},
		{`"ab" < "abc"`, "True"},
		{`"b" in "abc"`, "True"},
		{`"" in "abc"`, "True"},
		{`2 in [1, 2]`, "True"},
		{`"a" in d`, "True"},
		{`"z" not in d`, "True"},
		{`1 in range(3)`, "True"},
		// Access.
		{`d.a`, "1"},
		{`d["b"]`, "2"},
		{`l[0]`, "10"},
		{`l[-1]`, "30"},
		{`l[true]`, "20"},
		{`"héllo"[1]`, "é"},
		{`"abc"[-1]`, "c"},
		{`(l[5] is defined)`, "False"},
		{`(l[0] is defined)`, "True"},
		{`(l[5] is not defined)`, "True"},
		{`(d.zzz is defined)`, "False"},
		{`(l["a"] is defined)`, "False"},
		{`(l[1.0] is defined)`, "False"},
		{`(none.x is defined)`, "False"},
		{`(nosuch is defined)`, "False"},
		{`nosuch|default("d")`, "d"},
		{`nosuch|default`, ""},
		{`1 + (nosuch is defined)`, "1"},
		// Printing containers.
		{`[1, "a", true, none, 1.5, "it's", d]`, `[1, 'a', True, None, 1.5, "it's", {'a': 1, 'b': 2}]`},
		{`["a\"b'c"]`, `['a"b\'c']`},
		{`["a\nb\tc\\"]`, `['a\nb\tc\\']`},
		{`[]`, "[]"},
		// Filters.
		{`"aBc"|upper`, "ABC"},
		{`"aBc"|lower`, "abc"},
		{`"  x y \n"|trim`, "x y"},
		{`"<a href=\"x\">&'</a>"|escape`, "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;"},
		{`"a-b-c"|replace("-", "+")`, "a+b+c"},
		{`"héllo"|length`, "5"},
		{`l|length`, "3"},
		{`d|length`, "2"},
		{`"12"|int + 1`, "13"},
		{`"  -5 "|int`, "-5"},
		{`"3.9"|int`, "3"},
		{`"-3.9"|int`, "-3"},
		{`"1e3"|int`, "1000"},
		{`".5"|int`, "0"},
		{`"abc"|int`, "0"},
		{`"1.2.3"|int`, "0"},
		{`3.99|int`, "3"},
		{`-3.99|int`, "-3"},
		{`true|int`, "1"},
		{`none|int`, "0"},
		{`l|join(", ")`, "10, 20, 30"},
		{`l|join`, "102030"},
		{`"abc"|join("-")`, "a-b-c"},
		{`d|join(",")`, "a,b"},
		{`l|first`, "10"},
		{`l|last`, "30"},
		{`"abc"|first`, "a"},
		{`([]|first) is defined`, "False"},
		{`"abc"|reverse`, "cba"},
		{`l|reverse|join(",")`, "30,20,10"},
		{`[3, 1.5, 2]|sort|join(",")`, "1.5,2,3"},
		{`["b", "A", "a", "C"]|sort|join(",")`, "A,a,b,C"},
		{`[]|sort`, "[]"},
		{`"b"|default("x")`, "b"},
		{`"A"|lower|upper|trim`, "A"},
		{`-d.a|int`, "-1"},
		{`1 + "3"|int`, "4"},
		// range
		{`range(3)|join(",")`, "0,1,2"},
		{`range(1, 4)|join(",")`, "1,2,3"},
		{`range(5, 0, -2)|join(",")`, "5,3,1"},
		{`range(3)|length`, "3"},
		{`range(3)[1]`, "1"},
		// Strings.
		{`'it\'s'`, "it's"},
		{`"tab\there"`, "tab\there"},
		{`"%}"`, "%}"},
	}
	for _, tc := range tests {
		t.Run(tc.expr, func(t *testing.T) {
			in := `{"d": {"a": 1, "b": 2}, "l": [10, 20, 30]}` + "\n--\n=== m\n{{ " + tc.expr + " }}"
			if tc.expr == `1 + 2 ~ 3` {
				// 2 ~ 3 is "23"; 1 + "23" is a type error.
				if got := run(t, in); got != "error: type" {
					t.Errorf("got %q", got)
				}
				return
			}
			if got := run(t, in); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestErrors(t *testing.T) {
	tests := []struct{ name, tmpl, want string }{
		{"undefined print", `{{ x }}`, "undefined"},
		{"undefined truthiness", `{% if x %}{% endif %}`, "undefined"},
		{"undefined operator", `{{ x + 1 }}`, "undefined"},
		{"undefined eq", `{{ x == 1 }}`, "undefined"},
		{"undefined in", `{{ 1 in x }}`, "undefined"},
		{"undefined iteration", `{% for i in x %}{% endfor %}`, "undefined"},
		{"undefined call", `{{ x() }}`, "undefined"},
		{"undefined filter input", `{{ x|upper(1) }}`, "undefined"},
		{"undefined default arity", `{{ x|default(1, 2) }}`, "type"},
		{"undefined set then print", `{% set y = x %}{{ y }}`, "undefined"},
		{"undefined attr of undefined", `{{ d.q.r }}`, "undefined"},
		{"loop outside", `{{ loop.index }}`, "undefined"},
		{"super outside", `{{ super() }}`, "undefined"},
		{"unknown filter", `{{ 1|nope }}`, "filter"},
		{"unknown filter in macro", `{% macro m() %}{{ 1|nope }}{% endmacro %}`, "filter"},
		{"syntax before filter", `{{ 1|nope }}{{ }}`, "syntax"},
		{"missing include", `{% include "zzz" %}`, "template"},
		{"missing extends", `{% extends "zzz" %}`, "template"},
		{"include non-string", `{% include 1 %}`, "type"},
		{"include undefined", `{% include nope %}`, "undefined"},
		{"type add", `{{ 1 + "a" }}`, "type"},
		{"type sub", `{{ "a" - 1 }}`, "type"},
		{"type lt", `{{ 1 < "a" }}`, "type"},
		{"type neg", `{{ -"a" }}`, "type"},
		{"div zero", `{{ 1 / 0 }}`, "type"},
		{"floor div zero", `{{ 1 // 0 }}`, "type"},
		{"mod zero", `{{ 1 % 0 }}`, "type"},
		{"zero neg pow", `{{ 0 ** -1 }}`, "type"},
		{"in string with int", `{{ 1 in "abc" }}`, "type"},
		{"in int", `{{ 1 in 5 }}`, "type"},
		{"for over int", `{% for i in 5 %}{% endfor %}`, "type"},
		{"call int", `{{ 5() }}`, "type"},
		{"filter arity", `{{ "a"|upper(1) }}`, "type"},
		{"replace arity", `{{ "a"|replace("a") }}`, "type"},
		{"length of int", `{{ 5|length }}`, "type"},
		{"sort mixed", `{{ [1, "a"]|sort }}`, "type"},
		{"range zero step", `{{ range(1, 2, 0) }}`, "type"},
		{"range string", `{{ range("a") }}`, "type"},
		{"range kw", `{{ range(1, stop=2) }}`, "type"},
		{"range none", `{{ range() }}`, "type"},
		{"macro too many", `{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}`, "type"},
		{"macro unknown kw", `{% macro m(a) %}{% endmacro %}{{ m(b=1) }}`, "type"},
		{"macro dup kw", `{% macro m(a) %}{% endmacro %}{{ m(1, a=1) }}`, "type"},
		{"macro unbound param used", `{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}`, "undefined"},
		{"super args", `{% block b %}{{ super(1) }}{% endblock %}`, "type"},
		{"super no parent", `{% block b %}{{ super() }}{% endblock %}`, "undefined"},
		{"arg error beats callee", `{{ nope(1 + "a") }}`, "type"},
		{"unclosed var", `{{ 1`, "syntax"},
		{"unclosed stmt", `{% if 1 `, "syntax"},
		{"unclosed comment", `{# x`, "syntax"},
		{"triple brace", `{{{ 1 }}}`, "syntax"},
		{"bad escape", `{{ "\q" }}`, "syntax"},
		{"unterminated string", `{{ "abc }}`, "syntax"},
		{"unknown statement", `{% raw %}`, "syntax"},
		{"empty statement", `{% %}`, "syntax"},
		{"empty print", `{{ }}`, "syntax"},
		{"dangling operator", `{{ 1 - }}`, "syntax"},
		{"extra tokens", `{% if 1 2 %}{% endif %}`, "syntax"},
		{"stray endif", `{% endif %}`, "syntax"},
		{"else after else", `{% if 1 %}{% else %}{% else %}{% endif %}`, "syntax"},
		{"elif after else", `{% if 1 %}{% else %}{% elif 1 %}{% endif %}`, "syntax"},
		{"for tuple", `{% for a, b in x %}{% endfor %}`, "syntax"},
		{"for filter", `{% for a in x if a %}{% endfor %}`, "syntax"},
		{"set tuple", `{% set a, b = 1 %}`, "syntax"},
		{"include ignore missing", `{% include "x" ignore missing %}`, "syntax"},
		{"block scoped", `{% block x scoped %}{% endblock %}`, "syntax"},
		{"endblock wrong name", `{% block x %}{% endblock y %}`, "syntax"},
		{"duplicate block", `{% block x %}{% endblock %}{% block x %}{% endblock %}`, "syntax"},
		{"extends in if", `{% if 1 %}{% extends "m" %}{% endif %}`, "syntax"},
		{"extends twice", `{% extends "a" %}{% extends "b" %}`, "syntax"},
		{"conditional expression", `{{ 1 if 2 else 3 }}`, "syntax"},
		{"unknown test", `{{ 1 is even }}`, "syntax"},
		{"keyword name", `{% set and = 1 %}`, "syntax"},
		{"positional after keyword", `{{ f(a=1, 2) }}`, "syntax"},
		{"repeated keyword", `{{ f(a=1, a=2) }}`, "syntax"},
		{"trailing comma in call", `{{ f(1,) }}`, "syntax"},
		{"dict literal", `{{ {"a": 1} }}`, "syntax"},
		{"space before closer minus", `{{ x - }}`, "syntax"},
		{"duplicate macro param", `{% macro m(a, a) %}{% endmacro %}`, "syntax"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			in := `{"d": {"a": 1}}` + "\n--\n=== main\n" + tc.tmpl
			if got, want := run(t, in), "error: "+tc.want; got != want {
				t.Errorf("got %q, want %q", got, want)
			}
		})
	}
}

func TestRendering(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"whitespace control", "{}\n--\n=== m\na  {%- if 1 -%}  b  {%- endif -%}  c\n  {{- 'd' }}  {{ 'e' -}}  \n f {#- note -#}  g", "ab" + "c" + "d  e" + "f" + "g"},
		{"no automatic trimming", "{}\n--\n=== m\n  {% if 1 %}\nx\n  {% endif %}\n", "  \nx\n  "},
		{"minus before closer is operator when spaced", "{\"x\": 5}\n--\n=== m\n{{ x - 1 }}{{ x -1 }}{{ x-1 }}", "444"},
		{"comment", "{}\n--\n=== m\na{# {{ x }} {% bad #}b", "ab"},
		{"closer in string", "{}\n--\n=== m\n{{ \"%}}\" }}{% set a = '}}' %}{{ a }}", "%}}}}"},
		{"lone braces", "{}\n--\n=== m\n{ } {x} {%", "error: syntax"},
		{"trailing brace text", "{}\n--\n=== m\n{ } {x} }}", "{ } {x} }}"},
		{"for else keeps no loop", "{\"e\": []}\n--\n=== m\n{% for x in e %}a{% else %}empty{{ loop is defined }}{% endfor %}", "emptyFalse"},
		{"for else", "{\"e\": []}\n--\n=== m\n{% for x in e %}a{% else %}empty{% endfor %}", "empty"},
		{"loop vars", "{\"l\": [1,2,3]}\n--\n=== m\n{% for x in l %}{{ loop.index }}{{ loop.index0 }}{{ loop.first }}{{ loop.last }}{{ loop.length }} {% endfor %}", "10TrueFalse3 21FalseFalse3 32FalseTrue3 "},
		{"nested loop", "{}\n--\n=== m\n{% for i in range(2) %}{% for j in range(2) %}{{ loop.index }}{% endfor %}{{ loop.index }}{% endfor %}", "12112" + "2"},
		{"loop over string and dict", "{\"d\": {\"k\": 1, \"j\": 2}}\n--\n=== m\n{% for c in 'ab' %}{{ c }}{% endfor %}{% for k in d %}{{ k }}{% endfor %}", "abkj"},
		{"set in loop is local", "{}\n--\n=== m\n{% set a = 1 %}{% for i in range(2) %}{% set a = 2 %}{{ a }}{% endfor %}{{ a }}", "221"},
		{"if scope shared", "{}\n--\n=== m\n{% if 1 %}{% set a = 5 %}{% endif %}{{ a }}", "5"},
		{"macro", "{}\n--\n=== m\n{% macro m(a, b=a ~ '!') %}[{{ a }}{{ b }}]{% endmacro %}{{ m(1) }}{{ m(1, 2) }}{{ m(b=3, a=4) }}", "[11!][12][43]"},
		{"macro default sees later positional", "{}\n--\n=== m\n{% macro m(a=b, b=2) %}{{ a }}{{ b }}{% endmacro %}{{ m(b=5) }}", "55"},
		{"macro unbound is undefined", "{}\n--\n=== m\n{% macro m(a) %}{{ a is defined }}{% endmacro %}{{ m() }}", "False"},
		{"macro recursion", "{}\n--\n=== m\n{% macro f(n) %}{% if n < 2 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}{{ f(10) }}", "3628800"},
		{"macro does not see caller locals", "{}\n--\n=== m\n{% macro f() %}{{ x is defined }}{% endmacro %}{% for x in [1] %}{{ f() }}{% endfor %}", "False"},
		{"macro sees later set in definition scope", "{}\n--\n=== m\n{% macro f() %}{{ y }}{% endmacro %}{% set y = 3 %}{{ f() }}", "3"},
		{"macro output is string", "{}\n--\n=== m\n{% macro f() %}12{% endmacro %}{{ f() + 1 }}", "error: type"},
		{"include sees scope", "{\"x\": 1}\n--\n=== m\n{% set a = 2 %}{% for i in [3] %}{% include 'i' %}{% endfor %}{{ b is defined }}\n=== i\n{{ x }}{{ a }}{{ i }}{% set b = 1 %}", "123False"},
		{"include dynamic name", "{\"n\": \"i\"}\n--\n=== m\n{% include n ~ '' %}\n=== i\nI", "I"},
		{"extends basics", "{}\n--\n=== c\nbefore{% extends 'p' %}ignored{{ nope }}{% block b %}[C]{% endblock %}\n=== p\n<{% block b %}P{% endblock %}>", "before<[C]>"},
		{"extends skips text but runs set", "{}\n--\n=== c\n{% extends 'p' %}{% set v = 'V' %}{% macro m() %}M{% endmacro %}{% set w = m() %}{% block b %}{{ v }}{{ w }}{% endblock %}\n=== p\n{% block b %}{% endblock %}", "VM"},
		{"three level super", "{}\n--\n=== g\n{% extends 'c' %}{% block b %}G({{ super() }}){% endblock %}\n=== c\n{% extends 'p' %}{% block b %}C({{ super() }}){% endblock %}\n=== p\n{% block b %}P{% endblock %}", "G(C(P))"},
		{"block not in parent", "{}\n--\n=== c\n{% extends 'p' %}{% block zz %}Z{% endblock %}\n=== p\nP", "P"},
		{"nested blocks", "{}\n--\n=== c\n{% extends 'p' %}{% block inner %}I{% endblock %}\n=== p\n{% block outer %}[{% block inner %}i{% endblock %}]{% endblock %}", "[I]"},
		{"block does not see loop var", "{}\n--\n=== m\n{% for x in [1] %}{% block b %}{{ x is defined }}{% endblock %}{% endfor %}", "False"},
		{"parent macro visible in child block", "{}\n--\n=== c\n{% extends 'p' %}{% block b %}{{ m() }}{% endblock %}\n=== p\n{% macro m() %}M{% endmacro %}{% block b %}{% endblock %}", "M"},
		{"endblock name", "{}\n--\n=== m\n{% block x %}a{% endblock x %}", "a"},
		{"sort stable by lowered key", "{}\n--\n=== m\n{{ ['b', 'B', 'a', 'A']|sort|join('') }}", "aAbB"},
		{"dict iteration order", "{\"d\": {\"z\": 1, \"a\": 2}}\n--\n=== m\n{{ d }}{% for k in d %}{{ k }}{% endfor %}", "{'z': 1, 'a': 2}za"},
		{"json float and int", "{\"a\": 2.0, \"b\": 2, \"c\": 1e2}\n--\n=== m\n{{ a }} {{ b }} {{ c }}", "2.0 2 100.0"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tc.in); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestSetCachesAndReplaces(t *testing.T) {
	s := NewSet()
	s.Add("a", "{{ x }}")
	for i := 0; i < 2; i++ {
		got, err := s.Render("a", map[string]Value{"x": int64(i)})
		if err != nil || got != string(rune('0'+i)) {
			t.Fatalf("render %d = %q, %v", i, got, err)
		}
	}
	s.Add("a", "[{{ x }}]")
	if got, _ := s.Render("a", map[string]Value{"x": "y"}); got != "[y]" {
		t.Errorf("after replace got %q", got)
	}
	_, err := s.Render("missing", nil)
	var te *Error
	if !errors.As(err, &te) || te.Kind != KindTemplate {
		t.Errorf("missing template error = %v", err)
	}
}

func TestUnusedTemplateNotChecked(t *testing.T) {
	s := NewSet()
	s.Add("main", "ok")
	s.Add("broken", "{% if %}")
	if got, err := s.Render("main", nil); err != nil || got != "ok" {
		t.Errorf("got %q, %v", got, err)
	}
}

func TestLargeLoop(t *testing.T) {
	s := NewSet()
	s.Add("n", "{% for i in range(100000) %}{{ i }},{% endfor %}")
	if _, err := s.Render("n", nil); err != nil {
		t.Fatal(err)
	}
}

func BenchmarkRenderLoop(b *testing.B) {
	s := NewSet()
	s.Add("m", "{% for i in items %}<li>{{ i.name|upper }} {{ i.n * 2 }}</li>\n{% endfor %}")
	items := make([]Value, 20000)
	for i := range items {
		d := NewDict(2)
		d.Set("name", "item")
		d.Set("n", int64(i))
		items[i] = d
	}
	vars := map[string]Value{"items": items}
	for b.Loop() {
		if _, err := s.Render("m", vars); err != nil {
			b.Fatal(err)
		}
	}
}
