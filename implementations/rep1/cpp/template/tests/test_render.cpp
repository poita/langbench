// End-to-end rendering tests: each case is a document in the CLI input format.

#include <gtest/gtest.h>

#include "jinjalite/engine.hpp"

using namespace jinjalite;

namespace {

/// Renders `{ctx}\n--\n{templates}` and returns the output, or "error: kind".
std::string run(const std::string& ctx, const std::string& templates) {
  std::string out = render_document_or_error_line(ctx + "\n--\n" + templates);
  if (!out.empty() && out.back() == '\n') out.pop_back();
  return out;
}

/// Renders a single template `main` with an empty context.
std::string r(const std::string& body) { return run("{}", "=== main\n" + body); }

}  // namespace

TEST(Render, Text) {
  EXPECT_EQ(r("Just { text } and } and {"), "Just { text } and } and {");
  EXPECT_EQ(r(""), "");
}

TEST(Render, SpecWorkedExamples) {
  EXPECT_EQ(run(R"({"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3})",
                "=== main\nHi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n"
                "{% if n > 2 %}big{% endif %}"),
            "error: syntax");
  EXPECT_EQ(run(R"({"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3})",
                "=== main\nHi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n"
                "{% endfor -%}\n{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none"
                "{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}"),
            "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']");
  EXPECT_EQ(run(R"({"a": {"b": 1}})", "=== main\n{{ a.b }}{{ a.c.d }}"), "error: undefined");
}

TEST(Render, InheritanceWorkedExample) {
  EXPECT_EQ(run(R"({"title": "T", "items": [3, 1, 2]})",
                "=== page\n{% extends \"base\" %}\n{% set count = items|length %}\n"
                "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>"
                "{% endblock %}\n"
                "=== base\n{% macro item(v) %}#{{ v }}{% endmacro -%}\n"
                "<h1>{% block title %}{{ title }}{% endblock %}</h1>\n{% block body %}{{ count }} items{% endblock %}\n"
                "{% include \"footer\" %}\n"
                "=== footer\n-- {{ title|lower }} {{ missing|default(\"end\") }}"),
            "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end");
}

TEST(Render, Printing) {
  EXPECT_EQ(r("{{ true }} {{ none }} {{ 3.0 }} {{ 1.5 }} {{ [1, 'a', none] }}"), "True None 3.0 1.5 [1, 'a', None]");
  EXPECT_EQ(r("{{ 0.1 + 0.2 }} {{ 1e1 }}"), "error: syntax");  // no exponent literals
  EXPECT_EQ(run(R"({"d": {"k": [2.0, "it's"]}})", "=== main\n{{ d }}"), "{'k': [2.0, \"it's\"]}");
}

TEST(Render, Arithmetic) {
  EXPECT_EQ(r("{{ 1 + 2 * 3 }} {{ (1 + 2) * 3 }} {{ 7 // 2 }} {{ -7 // 2 }} {{ -7 % 3 }} {{ 7 % -3 }}"),
            "7 9 3 -4 2 -2");
  EXPECT_EQ(r("{{ 6 / 3 }} {{ 2 ** 10 }} {{ 2 ** -1 }} {{ -2 ** 2 }} {{ 2 ** 3 ** 2 }}"), "2.0 1024 0.5 4 64");
  EXPECT_EQ(r("{{ 'ab' * 3 }}{{ 2 * 'x' }}{{ 'a' ~ 1 ~ true }}{{ (1 + 2) ~ 3 }}"), "abababxxa1True33");
  EXPECT_EQ(r("{{ 1 / 0 }}"), "error: type");
  EXPECT_EQ(r("{{ 1 % 0 }}"), "error: type");
  EXPECT_EQ(r("{{ 'a' + 1 }}"), "error: type");
}

TEST(Render, LogicReturnsOperands) {
  EXPECT_EQ(r("{{ 0 or 'x' }}|{{ '' and 1 }}|{{ 1 and 2 }}|{{ not 0 }}|{{ 1 or missing }}|{{ 0 and missing }}"),
            "x||2|True|1|0");
}

TEST(Render, ComparisonChains) {
  EXPECT_EQ(r("{{ 1 < 2 < 3 }} {{ 1 < 3 < 2 }} {{ 1 == 1.0 }} {{ 1 > 2 > missing }} {{ 'a' < 'b' }}"),
            "True False True False True");
  EXPECT_EQ(r("{{ 1 < 'a' }}"), "error: type");
  EXPECT_EQ(r("{{ 1 == 'a' }} {{ none == 0 }} {{ [1] == [1.0] }}"), "False False True");
}

TEST(Render, Subscripts) {
  EXPECT_EQ(run(R"({"l": [1, 2, 3], "d": {"a": 1}, "s": "héy"})",
                "=== main\n{{ l[0] }}{{ l[-1] }}{{ d['a'] }}{{ s[1] }}{{ l[5] is defined }}{{ d.zz is defined }}"),
            "13" "1" "é" "FalseFalse");
  EXPECT_EQ(run(R"({"l": [1]})", "=== main\n{{ l[5] }}"), "error: undefined");
}

TEST(Render, IfForSet) {
  EXPECT_EQ(r("{% if 0 %}a{% elif '' %}b{% elif [1] %}c{% else %}d{% endif %}"), "c");
  EXPECT_EQ(run(R"({"xs": [1, 2, 3]})",
                "=== main\n{% for x in xs %}{{ loop.index }}/{{ loop.length }}{% if loop.first %}F{% endif %}"
                "{% if loop.last %}L{% endif %}{{ loop.index0 }},{% endfor %}"),
            "1/3F0,2/31,3/3L2,");
  EXPECT_EQ(r("{% for x in [] %}a{% else %}empty{% endfor %}"), "empty");
  EXPECT_EQ(r("{% for c in 'ab' %}{{ c }}-{% endfor %}"), "a-b-");
  EXPECT_EQ(run(R"({"d": {"x": 1, "y": 2}})", "=== main\n{% for k in d %}{{ k }}{% endfor %}"), "xy");
  EXPECT_EQ(r("{% for x in 5 %}{% endfor %}"), "error: type");
  EXPECT_EQ(r("{{ loop }}"), "error: undefined");
}

TEST(Render, LoopScoping) {
  // `set` inside a loop is iteration-local; the outer binding is untouched.
  EXPECT_EQ(r("{% set a = 1 %}{% for i in [1, 2] %}{% set a = a + i %}{{ a }}{% endfor %}{{ a }}"), "231");
  // Nested loops: `loop` is the innermost.
  EXPECT_EQ(r("{% for i in [1, 2] %}{% for j in [1, 2, 3] %}{{ loop.length }}{% endfor %}{{ loop.length }}{% endfor %}"),
            "33323332");
}

TEST(Render, Range) {
  EXPECT_EQ(r("{% for i in range(3) %}{{ i }}{% endfor %}{{ range(2, 5)|join(',') }}{{ range(5, 0, -2)|join(',') }}"),
            "012" "2,3,4" "5,3,1");
  EXPECT_EQ(r("{{ range(1, 2, 0) }}"), "error: type");
  EXPECT_EQ(r("{{ range('a') }}"), "error: type");
  EXPECT_EQ(r("{{ range() }}"), "error: type");
  EXPECT_EQ(r("{{ range(1, 2, 3, 4) }}"), "error: type");
  EXPECT_EQ(r("{{ range(1, k=2) }}"), "error: type");
  EXPECT_EQ(r("{{ range(missing) }}"), "error: undefined");
}

TEST(Render, Macros) {
  EXPECT_EQ(r("{% macro m(a, b=2) %}{{ a }}-{{ b }}{% endmacro %}{{ m(1) }} {{ m(1, 3) }} {{ m(b=5, a=0) }}"),
            "1-2 1-3 0-5");
  EXPECT_EQ(r("{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}{{ f(5) }}"),
            "120");
  EXPECT_EQ(r("{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, 2) }}"), "error: type");
  EXPECT_EQ(r("{% macro m(a) %}{{ a }}{% endmacro %}{{ m(c=2) }}"), "error: type");
  EXPECT_EQ(r("{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, a=2) }}"), "error: type");
  EXPECT_EQ(r("{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}"), "error: undefined");
  EXPECT_EQ(r("{% macro m(a, b=a) %}{{ b }}{% endmacro %}{{ m(4) }}"), "4");
  EXPECT_EQ(r("{% macro m(a) %}{{ a is defined }}{% endmacro %}{{ m() }}"), "False");
  EXPECT_EQ(r("{{ nosuch(1) }}"), "error: undefined");
  EXPECT_EQ(r("{{ 'x'(1) }}"), "error: type");
}

TEST(Render, MacroScoping) {
  // A macro sees later `set`s of its defining scope but not the caller's locals.
  EXPECT_EQ(r("{% macro m() %}{{ x }}{% endmacro %}{% set x = 'late' %}{{ m() }}"), "late");
  EXPECT_EQ(r("{% macro m() %}{{ y }}{% endmacro %}{% for y in [1] %}{{ m() }}{% endfor %}"), "error: undefined");
}

TEST(Render, UndefinedValue) {
  EXPECT_EQ(r("{{ x }}"), "error: undefined");
  EXPECT_EQ(r("{{ x is defined }}{{ x is not defined }}{{ x|default('d') }}"), "FalseTrued");
  EXPECT_EQ(r("{% if x %}{% endif %}"), "error: undefined");
  EXPECT_EQ(r("{{ x == 1 }}"), "error: undefined");
  EXPECT_EQ(r("{{ x|upper }}"), "error: undefined");
  EXPECT_EQ(r("{{ x|upper(1) }}"), "error: undefined");
  EXPECT_EQ(r("{{ x|default(1, 2) }}"), "error: type");
  EXPECT_EQ(r("{% set u = x %}{{ u is defined }}"), "False");
  EXPECT_EQ(r("{% for i in x %}{% endfor %}"), "error: undefined");
}

TEST(Render, FilterErrors) {
  EXPECT_EQ(r("{{ 1|nosuch }}"), "error: filter");
  EXPECT_EQ(r("{% if 0 %}{{ 1|nosuch }}{% endif %}"), "error: filter");  // checked at load
  EXPECT_EQ(r("{{ 'a'|upper(1) }}"), "error: type");
  EXPECT_EQ(r("{{ 'a'|replace('a') }}"), "error: type");
  EXPECT_EQ(r("{{ 1|length }}"), "error: type");
  EXPECT_EQ(r("{{ [1, 'a']|sort }}"), "error: type");
}

TEST(Render, Filters) {
  EXPECT_EQ(r("{{ ' Ab '|trim|upper }}{{ 'x'|replace('x', 'yy') }}{{ [3, 1, 2]|sort|join('') }}"), "AByy123");
  EXPECT_EQ(r("{{ 'abc'|reverse }}{{ [1, 2]|reverse|join(',') }}{{ '3.7'|int }}{{ 'a<b'|escape }}"),
            "cba2,13a&lt;b");
  EXPECT_EQ(r("{{ [1, 2]|first }}{{ [1, 2]|last }}{{ []|first|default('none') }}"), "12none");
  EXPECT_EQ(r("{{ 2 * '3'|int }}"), "6");
}

TEST(Render, WhitespaceControl) {
  EXPECT_EQ(r("a  {{- 1 -}}  b"), "a1b");
  EXPECT_EQ(r("a\n{% if 1 -%}\n  x\n{%- endif %}\nb"), "a\nx\nb");
  EXPECT_EQ(r("a {#- c -#} b"), "ab");
  EXPECT_EQ(r("a\n{% if 1 %}\n x\n{% endif %}\nb"), "a\n\n x\n\nb");
}

TEST(Render, Comments) {
  EXPECT_EQ(r("a{# anything {{ here }} {% there %} #}b"), "ab");
  EXPECT_EQ(r("a{# open"), "error: syntax");
}

TEST(Render, Include) {
  EXPECT_EQ(run(R"({"v": "ctx"})", "=== main\n{% set l = 'local' %}[{% include 'inc' %}]\n=== inc\n{{ v }} {{ l }}"),
            "[ctx local]");
  // Included template bindings are not visible to the includer.
  EXPECT_EQ(run("{}", "=== main\n{% include 'inc' %}{{ made }}\n=== inc\n{% set made = 1 %}"), "error: undefined");
  EXPECT_EQ(r("{% include 'nope' %}"), "error: template");
  EXPECT_EQ(r("{% include 5 %}"), "error: type");
  EXPECT_EQ(r("{% include nope %}"), "error: undefined");
  EXPECT_EQ(run("{}", "=== main\n{% include 'a' %}\n=== a\nA{% include 'b' %}\n=== b\nB"), "AB");
}

TEST(Render, BrokenTemplatesOnlyFailWhenLoaded) {
  EXPECT_EQ(run("{}", "=== main\nok\n=== bad\n{% if %}"), "ok");
  EXPECT_EQ(run("{}", "=== main\nok\n=== bad\n{{ 1|nosuch }}"), "ok");
  EXPECT_EQ(run("{}", "=== main\nbefore{% include 'bad' %}\n=== bad\n{% if %}"), "error: syntax");
  EXPECT_EQ(run("{}", "=== main\nbefore{% include 'bad' %}\n=== bad\n{{ 1|nosuch }}"), "error: filter");
}

TEST(Render, InheritanceBasics) {
  const char* tpl =
      "=== main\n{% extends 'base' %}{% block b %}child{% endblock %}ignored\n"
      "=== base\n[{% block a %}A{% endblock %}|{% block b %}base{% endblock %}]";
  EXPECT_EQ(run("{}", tpl), "[A|child]");
}

TEST(Render, SuperAndThreeLevels) {
  EXPECT_EQ(run("{}",
                "=== c\n{% extends 'b' %}{% block x %}C({{ super() }}){% endblock %}\n"
                "=== b\n{% extends 'a' %}{% block x %}B({{ super() }}){% endblock %}\n"
                "=== a\n<{% block x %}A{% endblock %}>"),
            "<C(B(A))>");
  EXPECT_EQ(run("{}", "=== a\n{% block x %}{{ super() }}{% endblock %}"), "error: undefined");
  EXPECT_EQ(run("{}", "=== c\n{% extends 'a' %}{% block x %}{{ super(1) }}{% endblock %}\n=== a\n{% block x %}{% endblock %}"),
            "error: type");
  EXPECT_EQ(r("{{ super() }}"), "error: undefined");
}

TEST(Render, TextBeforeExtendsIsKept) {
  EXPECT_EQ(run(R"({"t": "T"})", "=== c\nPre {{ t }}\n{% extends 'p' %}junk\n=== p\n<{% block b %}{% endblock %}>"),
            "Pre T\n<>");
}

TEST(Render, ChildSetsAndMacrosVisibleToParent) {
  EXPECT_EQ(run("{}",
                "=== c\n{% extends 'p' %}{% set v = 'child' %}{% macro m() %}M{% endmacro %}\n"
                "=== p\n{{ v }}{{ m() }}"),
            "childM");
}

TEST(Render, BlockScopesAreIsolated) {
  // A block does not see the loop variable of where the block tag appears...
  EXPECT_EQ(run("{}", "=== main\n{% set top = 1 %}{% block b %}{{ top }}{{ inner is defined }}{% endblock %}"), "1False");
  // ...nor sets from other blocks.
  EXPECT_EQ(run("{}", "=== main\n{% block a %}{% set s = 1 %}{% endblock %}{% block b %}{{ s is defined }}{% endblock %}"),
            "False");
}

TEST(Render, UndefinedChildBlockIsNeverRendered) {
  EXPECT_EQ(run("{}", "=== c\n{% extends 'p' %}{% block orphan %}X{% endblock %}\n=== p\nbase"), "base");
}

TEST(Render, ExtendsErrors) {
  EXPECT_EQ(r("{% extends 'nope' %}"), "error: template");
  EXPECT_EQ(r("{% extends nope %}"), "error: undefined");
  EXPECT_EQ(r("{% if 1 %}{% extends 'x' %}{% endif %}"), "error: syntax");
}

TEST(Render, UnknownDocumentSyntax) {
  EXPECT_EQ(r("{% raw %}x{% endraw %}"), "error: syntax");
  EXPECT_EQ(r("{{ x if y else z }}"), "error: syntax");
}

TEST(Render, LargeLoopIsFast) {
  std::string ctx = "{\"n\": 20000}";
  EXPECT_EQ(run(ctx, "=== main\n{% for i in range(n) %}{{ i }}{% endfor %}").size(), 88890u);
}
