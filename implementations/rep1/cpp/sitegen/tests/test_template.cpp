#include <gtest/gtest.h>

#include "sitegen/template.hpp"

using namespace sitegen;

namespace {

Value str(const std::string& s) { return Value::string(s); }
Value num(std::int64_t i) { return Value::integer(i); }

/// Renders template "main" (with the given extra templates) and returns the
/// output, or "error: <kind>".
std::string render(const std::string& main, const Dict& ctx = Dict(),
                   const std::vector<std::pair<std::string, std::string>>& others = {}) {
  TemplateEngine engine;
  engine.add_template("main", main);
  for (const auto& [name, src] : others) engine.add_template(name, src);
  try {
    return engine.render("main", ctx);
  } catch (const TemplateError& e) {
    return std::string("error: ") + to_string(e.kind());
  }
}

Dict user_context() {
  Dict user;
  user.set("name", str("Ada"));
  user.set("tags", Value::list({str("x"), str("y")}));
  Dict ctx;
  ctx.set("user", Value::dict(user));
  ctx.set("n", num(3));
  return ctx;
}

}  // namespace

TEST(Template, TextAndPrintingScalars) {
  Dict c;
  c.set("s", str("<b>"));
  c.set("t", Value::boolean(true));
  c.set("z", Value::none());
  c.set("f", Value::real(2.5));
  EXPECT_EQ(render("a{{ s }}b {{ t }} {{ z }} {{ f }} {{ 3 }}", c), "a<b>b True None 2.5 3");
}

TEST(Template, SpecExampleWithLoopAndWhitespaceControl) {
  EXPECT_EQ(render("Hi {{ user.name|upper }}!\n"
                   "{% for t in user.tags -%}\n"
                   "  {{ loop.index }}. {{ t }}\n"
                   "{% endfor -%}\n"
                   "{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %}"
                   " {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}",
                   user_context()),
            "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']");
}

TEST(Template, SpecExampleInheritanceMacroAndInclude) {
  Dict c;
  c.set("title", str("T"));
  c.set("items", Value::list({num(3), num(1), num(2)}));
  const std::string out = render(
      "{% extends \"base\" %}\n"
      "{% set count = items|length %}\n"
      "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}",
      c,
      {{"base",
        "{% macro item(v) %}#{{ v }}{% endmacro -%}\n"
        "<h1>{% block title %}{{ title }}{% endblock %}</h1>\n"
        "{% block body %}{{ count }} items{% endblock %}\n"
        "{% include \"footer\" %}"},
       {"footer", "-- {{ title|lower }} {{ missing|default(\"end\") }}"}});
  EXPECT_EQ(out, "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end");
}

TEST(Template, UndefinedAttributeAccessIsAnError) {
  Dict a;
  a.set("b", num(1));
  Dict c;
  c.set("a", Value::dict(a));
  EXPECT_EQ(render("{{ a.b }}{{ a.c.d }}", c), "error: undefined");
  EXPECT_EQ(render("{{ a.c is defined }} {{ a.b is not defined }}", c), "False False");
  EXPECT_EQ(render("{{ a.c|default('d') }}", c), "d");
}

TEST(Template, CommentsAndWhitespaceControl) {
  EXPECT_EQ(render("a {# hidden #} b"), "a  b");
  EXPECT_EQ(render("a  {#- hidden -#}  b"), "ab");
  EXPECT_EQ(render("a \n {{- 1 -}} \n b"), "a1b");
  EXPECT_EQ(render("x {%- if true -%} y {%- endif -%} z"), "xyz");
  EXPECT_EQ(render("{% if true %}\n  y\n{% endif %}"), "\n  y\n");
}

TEST(Template, ClosersInsideStringsDoNotEndTheTag) {
  EXPECT_EQ(render("{{ \"%}\" }}{{ '}}' }}"), "%}}}");
}

TEST(Template, ExpressionPrecedence) {
  EXPECT_EQ(render("{{ 1 + 2 * 3 }} {{ (1 + 2) * 3 }} {{ 2 ** 3 ** 2 }} {{ -2 ** 2 }} {{ 7 % 3 }} {{ -7 // 2 }} {{ -7 % 3 }}"),
            "7 9 64 4 1 -4 2");
}

TEST(Template, ConcatBindsTighterThanPlus) {
  EXPECT_EQ(render("{{ 1 ~ 2 + 3 }}"), "error: type");
  EXPECT_EQ(render("{{ 'a' ~ 'b' ~ 3 }}"), "ab3");
}

TEST(Template, FiltersBindTighterThanOperators) {
  Dict c;
  c.set("b", str("4"));
  c.set("n", num(4));
  EXPECT_EQ(render("{{ 2 * b|int }} {{ -n|int }} {{ 1 + b is defined }}", c), "8 -4 2");
}

TEST(Template, ComparisonChainsAndShortCircuit) {
  EXPECT_EQ(render("{{ 1 < 2 < 3 }} {{ 1 < 3 < 2 }} {{ 1 < 0 < missing }}"), "True False False");
  EXPECT_EQ(render("{{ 0 or 'x' }} {{ '' and 1 }}|{{ 1 and 2 }} {{ not 1 == 2 }}"), "x |2 True");
  EXPECT_EQ(render("{{ 1 or missing }} {{ 0 and missing }}"), "1 0");
}

TEST(Template, NumericSemantics) {
  EXPECT_EQ(render("{{ 6 / 3 }} {{ 7.0 // 2 }} {{ 2 ** -1 }} {{ 1 == 1.0 }} {{ true == 1 }} {{ true + true }}"),
            "2.0 3.0 0.5 True True 2");
  EXPECT_EQ(render("{{ 1 / 0 }}"), "error: type");
  EXPECT_EQ(render("{{ 1 % 0 }}"), "error: type");
  EXPECT_EQ(render("{{ 0 ** -1 }}"), "error: type");
  EXPECT_EQ(render("{{ 0.1 + 0.2 }}"), "0.30000000000000004");
  EXPECT_EQ(render("{{ 1e3 }}"), "error: syntax");
}

namespace {
Dict d_ctx() {
  Dict d;
  d.set("j", num(1));
  Dict c;
  c.set("d", Value::dict(d));
  return c;
}
}  // namespace

TEST(Template, StringOperations) {
  EXPECT_EQ(render("{{ 'ab' * 3 }}|{{ 2 * 'x' }}|{{ 'a' * 0 }}|{{ 'a' + 'b' }}|{{ [1] + [2] }}"), "ababab|xx||ab|[1, 2]");
  EXPECT_EQ(render("{{ 'a' in 'cat' }} {{ 'z' not in 'cat' }} {{ '' in 'abc' }} {{ 1 in [1, 2] }} {{ 'k' in d }}", d_ctx()),
            "True True True True False");
  EXPECT_EQ(render("{{ 1 in 'abc' }}"), "error: type");
}

TEST(Template, Indexing) {
  Dict c;
  c.set("l", Value::list({str("a"), str("b"), str("c")}));
  c.set("s", str("h\xC3\xA9llo"));
  EXPECT_EQ(render("{{ l[0] }}{{ l[-1] }} {{ s[1] }}{{ s[-1] }}", c), "ac \xC3\xA9o");
  EXPECT_EQ(render("{{ l[3] is defined }} {{ l['x'] is defined }} {{ s[9] is defined }}", c), "False False False");
}

TEST(Template, IfElifElse) {
  EXPECT_EQ(render("{% if 0 %}a{% elif '' %}b{% elif [1] %}c{% else %}d{% endif %}"), "c");
  EXPECT_EQ(render("{% if none %}a{% else %}d{% endif %}"), "d");
}

TEST(Template, ForLoopVariablesAndElse) {
  Dict c;
  c.set("items", Value::list({str("a"), str("b"), str("c")}));
  c.set("empty", Value::list({}));
  EXPECT_EQ(render("{% for i in items %}{{ loop.index }}/{{ loop.index0 }}/{{ loop.length }}"
                   "{% if loop.first %}F{% endif %}{% if loop.last %}L{% endif %}:{{ i }} {% endfor %}", c),
            "1/0/3F:a 2/1/3:b 3/2/3L:c ");
  EXPECT_EQ(render("{% for i in empty %}x{% else %}empty{% endfor %}", c), "empty");
  EXPECT_EQ(render("{% for ch in 'hé' %}[{{ ch }}]{% endfor %}"), "[h][\xC3\xA9]");
  EXPECT_EQ(render("{% for k in d %}{{ k }}{% endfor %}", [] {
              Dict d;
              d.set("z", num(1));
              d.set("a", num(2));
              Dict c2;
              c2.set("d", Value::dict(d));
              return c2;
            }()),
            "za");
  EXPECT_EQ(render("{{ loop }}"), "error: undefined");
}

TEST(Template, NestedLoopsUseInnermostLoop) {
  EXPECT_EQ(render("{% for a in [1, 2] %}{% for b in [1, 2, 3] %}{{ loop.length }}{% endfor %}{{ loop.length }}{% endfor %}"),
            "33323332");
}

TEST(Template, SetScopesAreLexical) {
  EXPECT_EQ(render("{% set x = 1 %}{% for i in [1, 2] %}{% set x = i %}{{ x }}{% endfor %}{{ x }}"), "121");
  EXPECT_EQ(render("{% set a = 1 %}{% if true %}{% set b = 2 %}{% endif %}{{ a }}{{ b }}"), "12");
}

TEST(Template, RangeBuiltin) {
  EXPECT_EQ(render("{% for i in range(3) %}{{ i }}{% endfor %}|{% for i in range(2, 5) %}{{ i }}{% endfor %}|"
                   "{% for i in range(5, 0, -2) %}{{ i }}{% endfor %}"),
            "012|234|531");
  EXPECT_EQ(render("{{ range(0) | length }} {{ range(10)|join(',') }}"), "0 0,1,2,3,4,5,6,7,8,9");
  EXPECT_EQ(render("{{ range() }}"), "error: type");
  EXPECT_EQ(render("{{ range(1, 2, 0) }}"), "error: type");
  EXPECT_EQ(render("{{ range('a') }}"), "error: type");
}

TEST(Template, Macros) {
  EXPECT_EQ(render("{% macro f(a, b=2) %}{{ a }}-{{ b }}{% endmacro %}{{ f(1) }} {{ f(1, 3) }} {{ f(b=5, a=4) }}"),
            "1-2 1-3 4-5");
  EXPECT_EQ(render("{% macro fact(n) %}{% if n <= 1 %}1{% else %}{{ n * fact(n - 1)|int }}{% endif %}{% endmacro %}{{ fact(5) }}"),
            "120");
  EXPECT_EQ(render("{% macro f(a, b=a ~ '!') %}{{ b }}{% endmacro %}{{ f('x') }}"), "x!");
  EXPECT_EQ(render("{% macro f(a) %}{{ a is defined }}{% endmacro %}{{ f() }}"), "False");
  EXPECT_EQ(render("{% macro f(a) %}{{ a }}{% endmacro %}{{ f(1, 2) }}"), "error: type");
  EXPECT_EQ(render("{% macro f(a) %}{{ a }}{% endmacro %}{{ f(b=1) }}"), "error: type");
  EXPECT_EQ(render("{% macro f(a) %}{{ a }}{% endmacro %}{{ f(1, a=2) }}"), "error: type");
  EXPECT_EQ(render("{% macro f() %}{{ x }}{% endmacro %}{% set x = 'late' %}{{ f() }}"), "late");
}

TEST(Template, MacrosDoNotSeeCallerLocals) {
  EXPECT_EQ(render("{% macro f() %}{{ y is defined }}{% endmacro %}{% for y in [1] %}{{ f() }}{% endfor %}"), "False");
}

TEST(Template, IncludeSharesTheCurrentScope) {
  Dict c;
  c.set("v", str("V"));
  EXPECT_EQ(render("{% set local = 'L' %}[{% include 'part' %}][{{ made is defined }}]", c,
                   {{"part", "{{ v }}{{ local }}{% set made = 1 %}"}}),
            "[VL][False]");
  EXPECT_EQ(render("{% include 'nope' %}"), "error: template");
  EXPECT_EQ(render("{% include 1 %}"), "error: type");
  EXPECT_EQ(render("{% include missing %}"), "error: undefined");
}

TEST(Template, ThreeLevelInheritanceAndSuper) {
  const std::vector<std::pair<std::string, std::string>> others = {
      {"child", "{% extends 'base' %}{% block b %}C({{ super() }}){% endblock %}"},
      {"base", "<{% block a %}A{% endblock %}|{% block b %}B{% endblock %}>"},
  };
  EXPECT_EQ(render("{% extends 'child' %}{% block a %}a{% endblock %}{% block b %}G({{ super() }}){% endblock %}", Dict(), others),
            "<a|G(C(B))>");
}

TEST(Template, ChildTextOutsideBlocksIsSkippedButBeforeExtendsIsKept) {
  EXPECT_EQ(render("before|{% extends 'base' %}ignored{% set x = 'S' %}{% block b %}{{ x }}{% endblock %}trailing", Dict(),
                   {{"base", "[{% block b %}{% endblock %}]"}}),
            "before|[S]");
}

TEST(Template, BlockScopeIsTheTemplateScope) {
  EXPECT_EQ(render("{% set top = 'T' %}{% for i in [1] %}{% block b %}{{ top }}{{ i is defined }}{% endblock %}{% endfor %}"),
            "TFalse");
}

TEST(Template, SuperWithoutParentIsUndefined) {
  EXPECT_EQ(render("{% block b %}{{ super() }}{% endblock %}"), "error: undefined");
  EXPECT_EQ(render("{{ super() }}"), "error: undefined");
}

TEST(Template, StringFilters) {
  EXPECT_EQ(render("{{ 'aB\xC3\xA9'|upper }} {{ 'aB\xC3\x89'|lower }} [{{ ' \t x y \n'|trim }}]"), "AB\xC3\xA9 ab\xC3\x89 [x y]");
  EXPECT_EQ(render("{{ '<a href=\"x\">&\\'</a>'|escape }}"), "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;");
  EXPECT_EQ(render("{{ 'aaa'|replace('a', 'bb') }} {{ 'x.y'|replace('.', '') }}"), "bbbbbb xy");
  EXPECT_EQ(render("{{ 'h\xC3\xA9llo'|length }} {{ [1, 2]|length }} {{ 5|length }}"), "error: type");
}

TEST(Template, IntFilter) {
  EXPECT_EQ(render("{{ ' 42 '|int }} {{ '-7'|int }} {{ '+3'|int }} {{ '3.9'|int }} {{ '-3.9'|int }} {{ '1e2'|int }} "
                   "{{ 'abc'|int }} {{ 2.7|int }} {{ true|int }} {{ none|int }} {{ '.5'|int }} {{ ''|int }}"),
            "42 -7 3 3 -3 100 0 2 1 0 0 0");
}

TEST(Template, SequenceFilters) {
  Dict c;
  c.set("l", Value::list({num(3), num(1), num(2)}));
  c.set("w", Value::list({str("b"), str("A"), str("a"), str("B")}));
  EXPECT_EQ(render("{{ l|sort }} {{ l|reverse }} {{ l|first }} {{ l|last }} {{ l|join('-') }} {{ w|sort }}", c),
            "[1, 2, 3] [2, 1, 3] 3 2 3-1-2 ['A', 'a', 'b', 'B']");
  EXPECT_EQ(render("{{ 'abc'|reverse }} {{ 'abc'|first }} {{ 'abc'|join(',') }} {{ []|first is defined }}"), "cba a a,b,c False");
  EXPECT_EQ(render("{{ [1, 'a']|sort }}"), "error: type");
  EXPECT_EQ(render("{{ 5|join }}"), "error: type");
}

TEST(Template, DefaultFilter) {
  EXPECT_EQ(render("{{ x|default }}|{{ x|default('d') }}|{{ 0|default('d') }}"), "|d|0");
  EXPECT_EQ(render("{{ x|default(1, 2) }}"), "error: type");
}

TEST(Template, FilterErrorOrder) {
  EXPECT_EQ(render("{{ x|upper(1) }}"), "error: undefined");
  EXPECT_EQ(render("{{ 'a'|upper(1) }}"), "error: type");
  EXPECT_EQ(render("{{ 'a'|nosuch }}"), "error: filter");
  EXPECT_EQ(render("{% if false %}{{ 'a'|nosuch }}{% endif %}"), "error: filter");
  EXPECT_EQ(render("{{ 'a'|upper("), "error: syntax");
}

TEST(Template, UndefinedValueRules) {
  EXPECT_EQ(render("{{ x }}"), "error: undefined");
  EXPECT_EQ(render("{% if x %}a{% endif %}"), "error: undefined");
  EXPECT_EQ(render("{{ x == 1 }}"), "error: undefined");
  EXPECT_EQ(render("{% for i in x %}{% endfor %}"), "error: undefined");
  EXPECT_EQ(render("{{ x() }}"), "error: undefined");
  EXPECT_EQ(render("{% set y = x %}{{ y is defined }}"), "False");
  EXPECT_EQ(render("{{ 1() }}"), "error: type");
}

TEST(Template, SyntaxErrors) {
  for (const char* bad : {"{% if true %}", "{% endif %}", "{% for x in y %}{% endif %}", "{{ 1 + }}",
                          "{{ 'unterminated }}", "{{ 'bad \\q escape' }}", "{{ a if b else c }}", "{% raw %}",
                          "{{{ x }}}", "{# unclosed", "{{ x - }}", "{% set a, b = 1 %}", "{% for a, b in x %}{% endfor %}",
                          "{% block a %}{% endblock b %}", "{% block a %}{% endblock %}{% block a %}{% endblock %}",
                          "{% if true %}{% extends 'x' %}{% endif %}", "{% extends 'a' %}{% extends 'b' %}",
                          "{{ x is odd }}", "{{ 1.5.2 }}", "{{ f(a=1, 2) }}", "{{ f(a=1, a=2) }}", "{% %}",
                          "{% macro m(a, a) %}{% endmacro %}", "{{ [1, 2,] }}", "{{ x.0 }}", "{{ a $ b }}"}) {
    EXPECT_EQ(render(bad), "error: syntax") << bad;
  }
}

TEST(Template, UnusedTemplatesAreNeverParsed) {
  EXPECT_EQ(render("ok", Dict(), {{"broken", "{% if %}"}}), "ok");
  EXPECT_EQ(render("{% include 'broken' %}", Dict(), {{"broken", "{% if %}"}}), "error: syntax");
}

TEST(Template, DictAndListPrinting) {
  Dict inner;
  inner.set("a", num(1));
  Dict c;
  c.set("d", Value::dict(inner));
  EXPECT_EQ(render("{{ d }} {{ [d, none, 'x'] }} {{ d.a }}", c), "{'a': 1} [{'a': 1}, None, 'x'] 1");
}

TEST(Template, RendersTheSameTemplateRepeatedly) {
  TemplateEngine engine;
  engine.add_template("t", "{% set a = n * 2 %}{{ a }}");
  for (int i = 0; i < 3; ++i) {
    Dict c;
    c.set("n", num(i));
    EXPECT_EQ(engine.render("t", c), std::to_string(i * 2));
  }
  EXPECT_TRUE(engine.has_template("t"));
  EXPECT_FALSE(engine.has_template("u"));
  EXPECT_THROW(engine.render("u", Dict()), TemplateError);
}
