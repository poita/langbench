#include <gtest/gtest.h>

#include "jinjalite/error.hpp"
#include "jinjalite/parser.hpp"

using namespace jinjalite;

namespace {
ErrorKind parse_error(const std::string& src) {
  try {
    parse_template("t", src);
  } catch (const Error& e) {
    return e.kind();
  }
  ADD_FAILURE() << "no error for: " << src;
  return ErrorKind::Type;
}
}  // namespace

TEST(Parser, ParsesAllStatements) {
  auto t = parse_template(
      "t",
      "{% macro m(a, b=1) %}x{% endmacro %}{% for i in [1] %}{{ i }}{% else %}-{% endfor %}"
      "{% if a %}1{% elif b %}2{% else %}3{% endif %}{% set z = 1 %}{% include 'x' %}"
      "{% block one %}{% block two %}{% endblock two %}{% endblock %}");
  EXPECT_EQ(t->blocks.size(), 2u);
  EXPECT_EQ(t->body.size(), 6u);
}

TEST(Parser, ExtendsRules) {
  EXPECT_NO_THROW(parse_template("t", "x{% extends 'a' %}{% block b %}{% endblock %}"));
  EXPECT_EQ(parse_error("{% extends 'a' %}{% extends 'b' %}"), ErrorKind::Syntax);
  EXPECT_EQ(parse_error("{% if 1 %}{% extends 'a' %}{% endif %}"), ErrorKind::Syntax);
  EXPECT_EQ(parse_error("{% block b %}{% extends 'a' %}{% endblock %}"), ErrorKind::Syntax);
}

TEST(Parser, BlockRules) {
  EXPECT_EQ(parse_error("{% block a %}{% endblock %}{% block a %}{% endblock %}"), ErrorKind::Syntax);
  EXPECT_EQ(parse_error("{% block a %}{% endblock b %}"), ErrorKind::Syntax);
  EXPECT_EQ(parse_error("{% block a scoped %}{% endblock %}"), ErrorKind::Syntax);
}

TEST(Parser, UnbalancedAndUnknownStatements) {
  for (const char* s : {"{% if x %}", "{% endif %}", "{% for x in y %}", "{% else %}", "{% raw %}", "{% %}",
                        "{% call f() %}", "{% with a=1 %}", "{% if x %}{% else %}{% else %}{% endif %}",
                        "{% if x %}{% else %}{% elif y %}{% endif %}", "{% endfor extra %}"}) {
    EXPECT_EQ(parse_error(s), ErrorKind::Syntax) << s;
  }
}

TEST(Parser, StatementFormsAreExact) {
  for (const char* s : {"{% for a, b in x %}{% endfor %}", "{% for x in y if z %}{% endfor %}",
                        "{% set a, b = 1 %}", "{% include 'x' ignore missing %}", "{% set in = 1 %}",
                        "{% macro m %}{% endmacro %}", "{% macro m(a, a) %}{% endmacro %}",
                        "{% macro m(a,) %}{% endmacro %}"}) {
    EXPECT_EQ(parse_error(s), ErrorKind::Syntax) << s;
  }
}

TEST(Parser, ExpressionErrors) {
  for (const char* s : {"{{ }}", "{{ x - }}", "{{ a if b else c }}", "{{ (1, 2) }}", "{{ x[1:2] }}",
                        "{{ f(a=1, 2) }}", "{{ f(a=1, a=2) }}", "{{ x is odd }}", "{{ [1, 2,] }}",
                        "{{ x|f(1,) }}", "{{ not }}", "{{ + 1 }}", "{{ a not b }}", "{{ and }}"}) {
    EXPECT_EQ(parse_error(s), ErrorKind::Syntax) << s;
  }
}

TEST(Parser, UnknownFilter) {
  EXPECT_EQ(parse_error("{% if 0 %}{{ x|nosuch }}{% endif %}"), ErrorKind::Filter);
  // A syntax error takes precedence over an unknown filter.
  EXPECT_EQ(parse_error("{{ x|nosuch }}{% if %}"), ErrorKind::Syntax);
}

TEST(Parser, GrammarCornerCases) {
  for (const char* s : {"{{ a * b|int }}", "{{ -x|int }}", "{{ 1 + x is defined }}", "{{ not a == b }}",
                        "{{ a < b < c }}", "{{ a not in b }}", "{{ x.y|upper }}", "{{ (5).x }}",
                        "{{ f(1, k=2) }}", "{{ 2 ** -1 }}", "{{ x is not defined }}", "{{ 'a' ~ 1 ~ 'b' }}"}) {
    EXPECT_NO_THROW(parse_template("t", s)) << s;
  }
}
