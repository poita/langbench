package template_test

import (
	"fmt"
	"strings"
	"testing"

	"example.com/template"
	"example.com/template/jsonctx"
)

// render renders the template "main" from sources (name -> body) with the
// JSON context ctx.
func render(t *testing.T, ctx string, sources map[string]string) (string, error) {
	t.Helper()
	d, err := jsonctx.Parse(ctx)
	if err != nil {
		t.Fatal(err)
	}
	env := template.NewEnvironment()
	for name, body := range sources {
		env.Add(name, body)
	}
	return env.Render("main", d)
}

func main(body string) map[string]string { return map[string]string{"main": body} }

func TestRender(t *testing.T) {
	tests := []struct {
		name, ctx string
		src       map[string]string
		want      string
	}{
		{"text", `{}`, main("plain {text} }"), "plain {text} }"},
		{"variables", `{"u": {"name": "Ada", "tags": ["x", "y"]}, "n": 3}`, main(`{{ u.name|upper }} {{ u.tags[-1] }} {{ n * 2 }}`), "ADA y 6"},
		{"arithmetic", `{}`, main(`{{ 7 / 2 }} {{ 7 // 2 }} {{ -7 // 2 }} {{ -7 % 3 }} {{ 2 ** 10 }} {{ 6 / 3 }} {{ 1 + 2.5 }} {{ "ab" * 2 }}`), "3.5 3 -4 2 1024 2.0 3.5 abab"},
		{"logic returns operands", `{}`, main(`{{ 0 or "x" }}|{{ "" and 1 }}|{{ 1 and 2 }}|{{ not 0 }}`), "x||2|True"},
		{"compare chain", `{}`, main(`{{ 1 < 2 < 3 }} {{ 3 > 2 > 2 }} {{ 1 == 1.0 }} {{ "a" in "abc" }} {{ 2 not in [1, 2] }}`), "True False True True False"},
		{"short circuit", `{}`, main(`{{ 3 < 2 < nope }}{{ 1 or nope }}`), "False1"},
		{"printing", `{}`, main(`{{ [1, 'a', true, none, 1.5, "it's", 0.1 + 0.2] }}`), `[1, 'a', True, None, 1.5, "it's", 0.30000000000000004]`},
		{"if", `{"n": 3}`, main(`{% if n > 5 %}a{% elif n > 2 %}b{% else %}c{% endif %}`), "b"},
		{"for", `{}`, main(`{% for x in "ab" %}{{ loop.index0 }}{{ x }}{% if loop.first %}F{% endif %}{% if loop.last %}L{% endif %}{{ loop.length }}{% endfor %}`), "0aF21bL2"},
		{"for else", `{"e": []}`, main(`{% for x in e %}x{% else %}none{% endfor %}`), "none"},
		{"for over dict keys", `{"d": {"b": 1, "a": 2}}`, main(`{% for k in d %}{{ k }}={{ d[k] }};{% endfor %}`), "b=1;a=2;"},
		{"set scoping", `{}`, main(`{% set x = 1 %}{% for i in [1] %}{% set x = 2 %}{{ x }}{% endfor %}{{ x }}`), "21"},
		{"range", `{}`, main(`{{ range(3)|join(",") }} {{ range(1, 6, 2)|join(",") }} {{ range(3, 0, -1)|join(",") }}`), "0,1,2 1,3,5 3,2,1"},
		{"macro", `{}`, main(`{% macro f(a, b=a ~ "!") %}{{ a }}{{ b }}{% endmacro %}{{ f("x") }}{{ f("y", b="z") }}`), "xx!yz"},
		{"macro recursion", `{}`, main(`{% macro fact(n) %}{% if n <= 1 %}1{% else %}{{ n * fact(n - 1)|int }}{% endif %}{% endmacro %}{{ fact(10) }}`), "3628800"},
		{"macro sees later set", `{}`, main(`{% macro m() %}{{ v }}{% endmacro %}{% set v = 5 %}{{ m() }}`), "5"},
		{"macro undefined param unused", `{}`, main(`{% macro m(a) %}ok{% endmacro %}{{ m() }}`), "ok"},
		{"include sees scope", `{"v": 1}`, map[string]string{"main": `{% set s = 2 %}{% for i in [7] %}{% include "inc" %}{% endfor %}{{ leaked is defined }}`, "inc": `{{ v }}{{ s }}{{ i }}{% set leaked = 1 %}`}, "127False"},
		{"dynamic include", `{"which": "b"}`, map[string]string{"main": `{% include which %}`, "b": `B`}, "B"},
		{"whitespace control", `{}`, main("a  \n{%- if true -%}  \n b {{- 1 -}} \n{%- endif %}\n c"), "ab1\n c"},
		{"comment", `{}`, main("a{# {{ x }} #}b{#- c -#}  d"), "abd"},
		{"default and defined", `{}`, main(`{{ x|default("d") }}{{ x is defined }}{{ x is not defined }}{{ 1 is defined }}`), "dFalseTrueTrue"},
		{"undefined can be stored", `{}`, main(`{% set u = nope %}{{ u is defined }}{{ u|default(1) }}`), "False1"},
		{"string index by code point", `{}`, main(`{{ "héllo"[1] }}{{ "héllo"[-1] }}{{ "héllo"|length }}`), "éo5"},
		{"bool is int", `{}`, main(`{{ true + true }} {{ [10, 20][true] }} {{ true == 1 }}`), "2 20 True"},
		{"float printing", `{}`, main(`{{ 1000000000000000.0 }} {{ 10000000000000000.0 }} {{ 0.00001 }} {{ 3.0 }} {{ 10 ** 17 / 10 }}`), "1000000000000000.0 1e+16 1e-05 3.0 1e+16"},
		{"filters chain", `{}`, main(`{{ "  Hi <b> "|trim|upper|escape }} {{ [3,1,2]|sort|reverse|join("") }}`), "HI &lt;B&gt; 321"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := render(t, tc.ctx, tc.src)
			if err != nil {
				t.Fatalf("error: %v", err)
			}
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestInheritance(t *testing.T) {
	src := map[string]string{
		"main": `{% extends "base" %}{% set count = items|length %}` +
			`{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}`,
		"base": "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n" +
			"{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}",
		"footer": `-- {{ title|lower }} {{ missing|default("end") }}`,
	}
	got, err := render(t, `{"title": "T", "items": [3, 1, 2]}`, src)
	if err != nil {
		t.Fatal(err)
	}
	want := "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestInheritanceThreeLevels(t *testing.T) {
	src := map[string]string{
		"main": `{% extends "mid" %}{% block a %}[main {{ super() }}]{% endblock %}`,
		"mid":  `before{% extends "base" %}{% block a %}[mid {{ super() }}]{% endblock %}ignored`,
		"base": `<{% block a %}base{% endblock %}>`,
	}
	got, err := render(t, `{}`, src)
	if err != nil {
		t.Fatal(err)
	}
	if want := "before<[main [mid base]]>"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestTextBeforeExtendsIsKept(t *testing.T) {
	src := map[string]string{
		"main": `head {% extends "base" %} skipped {{ nope }}{% block b %}child{% endblock %}`,
		"base": `[{% block b %}base{% endblock %}]`,
	}
	got, err := render(t, `{}`, src)
	if err != nil || got != "head [child]" {
		t.Errorf("got %q, %v", got, err)
	}
}

func TestBlockScopeIsTemplateScope(t *testing.T) {
	src := map[string]string{
		"main": `{% set top = "T" %}{% for x in [1] %}{% block b %}{{ top }}{{ x is defined }}{% endblock %}{% endfor %}`,
	}
	// Blocks inside for bodies are outside the guarantees, but the scope rule
	// still applies: the block cannot see the loop variable.
	got, err := render(t, `{}`, src)
	if err != nil || got != "TFalse" {
		t.Errorf("got %q, %v", got, err)
	}
}

func TestErrors(t *testing.T) {
	tests := []struct {
		name string
		src  map[string]string
		want template.Kind
	}{
		{"undefined variable", main(`{{ x }}`), template.Undefined},
		{"undefined attribute chain", main(`{{ a.b.c }}`), template.Undefined},
		{"undefined truthiness", main(`{% if x %}{% endif %}`), template.Undefined},
		{"undefined compare", main(`{{ x == 1 }}`), template.Undefined},
		{"undefined call", main(`{{ nope() }}`), template.Undefined},
		{"loop outside for", main(`{{ loop.index }}`), template.Undefined},
		{"super without parent", main(`{% block b %}{{ super() }}{% endblock %}`), template.Undefined},
		{"undefined after output", main(`lots of output {{ x }}`), template.Undefined},
		{"syntax", main(`{% for x in y %}`), template.Syntax},
		{"syntax beats filter", main(`{{ x|nope }}{% if %}`), template.Syntax},
		{"filter in unexecuted branch", main(`{% if false %}{{ x|nope }}{% endif %}`), template.Filter},
		{"filter before runtime error", main(`{{ x }}{{ y|nope }}`), template.Filter},
		{"missing include", main(`{% include "zzz" %}`), template.Template},
		{"missing extends", main(`{% extends "zzz" %}`), template.Template},
		{"include non-string", main(`{% include 5 %}`), template.Type},
		{"include undefined", main(`{% include nope %}`), template.Undefined},
		{"string plus int", main(`{{ "a" + 1 }}`), template.Type},
		{"division by zero", main(`{{ 1 / 0 }}`), template.Type},
		{"iterate int", main(`{% for x in 5 %}{% endfor %}`), template.Type},
		{"call non-callable", main(`{% set a = 1 %}{{ a() }}`), template.Type},
		{"macro too many args", main(`{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}`), template.Type},
		{"macro unknown kwarg", main(`{% macro m(a) %}{% endmacro %}{{ m(b=1) }}`), template.Type},
		{"macro duplicate arg", main(`{% macro m(a) %}{% endmacro %}{{ m(1, a=2) }}`), template.Type},
		{"macro unused undefined param used", main(`{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}`), template.Undefined},
		{"filter arity", main(`{{ "x"|upper(1) }}`), template.Type},
		{"filter arity vs undefined", main(`{{ x|upper(1) }}`), template.Undefined},
		{"range zero step", main(`{{ range(1, 2, 0) }}`), template.Type},
		{"range kwargs checked first", main(`{{ range(x, a=1) }}`), template.Type},
		{"super with args", map[string]string{"main": `{% extends "b" %}{% block x %}{{ super(1) }}{% endblock %}`, "b": `{% block x %}{% endblock %}`}, template.Type},
		{"error in included", map[string]string{"main": `before{% include "i" %}`, "i": `{{ nope }}`}, template.Undefined},
		{"syntax in included", map[string]string{"main": `before{% include "i" %}`, "i": `{% if %}`}, template.Syntax},
		{"argument error wins over callee", main(`{{ nope(1/0) }}`), template.Type},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := render(t, `{"a": {}}`, tc.src)
			if k, ok := template.KindOf(err); !ok || k != tc.want {
				t.Fatalf("got output %q, error %v; want kind %s", got, err, tc.want)
			}
			if got != "" {
				t.Errorf("partial output %q on error", got)
			}
		})
	}
}

func TestUnusedBrokenTemplateIsNeverLoaded(t *testing.T) {
	got, err := render(t, `{}`, map[string]string{"main": `ok`, "broken": `{% if %}{{ x|nope }}`})
	if err != nil || got != "ok" {
		t.Errorf("got %q, %v", got, err)
	}
}

func TestRenderGoContext(t *testing.T) {
	env := template.NewEnvironment()
	env.Add("main", `{{ name|upper }} {{ items|join("+") }} {{ n + 1 }} {{ f * 2 }}`)
	got, err := env.Render("main", map[string]any{"name": "ada", "items": []any{1, 2}, "n": 41, "f": 1.5})
	if err != nil || got != "ADA 1+2 42 3.0" {
		t.Errorf("got %q, %v", got, err)
	}
	if _, err := env.Render("main", 5); err == nil {
		t.Error("non-dict context accepted")
	}
	if _, err := env.Render("absent", nil); err == nil {
		t.Error("missing template accepted")
	}
}

func TestReAddInvalidatesCache(t *testing.T) {
	env := template.NewEnvironment()
	env.Add("main", "one")
	_, _ = env.Render("main", nil)
	env.Add("main", "two")
	if got, _ := env.Render("main", nil); got != "two" {
		t.Errorf("got %q", got)
	}
}

func TestIncludeCycleFailsCleanly(t *testing.T) {
	env := template.NewEnvironment()
	env.Add("main", `{% include "main" %}`)
	if _, err := env.Render("main", nil); err == nil {
		t.Error("include cycle succeeded")
	}
}

func TestLargeLoop(t *testing.T) {
	var sb strings.Builder
	sb.WriteString(`{"xs": [`)
	for i := 0; i < 20000; i++ {
		if i > 0 {
			sb.WriteByte(',')
		}
		fmt.Fprintf(&sb, `"v%d"`, i)
	}
	sb.WriteString(`]}`)
	got, err := render(t, sb.String(), main(`{% for x in xs %}{{ x|upper }},{% endfor %}`))
	if err != nil || !strings.HasSuffix(got, "V19999,") {
		t.Errorf("err %v, tail %q", err, got[max(0, len(got)-10):])
	}
}

func ExampleEnvironment_Render() {
	env := template.NewEnvironment()
	env.Add("base", `<h1>{% block title %}Untitled{% endblock %}</h1>`)
	env.Add("page", `{% extends "base" %}{% block title %}{{ super() }} - {{ name|upper }}{% endblock %}`)
	out, err := env.Render("page", map[string]any{"name": "ada"})
	fmt.Println(out, err)
	// Output: <h1>Untitled - ADA</h1> <nil>
}
