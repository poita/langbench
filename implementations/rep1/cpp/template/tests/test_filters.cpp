#include <gtest/gtest.h>

#include "jinjalite/error.hpp"
#include "jinjalite/filters.hpp"
#include "jinjalite/format.hpp"
#include "jinjalite/json.hpp"

using namespace jinjalite;

namespace {
Value apply(const char* name, const Value& in, std::vector<Value> args = {}) {
  const FilterInfo* f = find_filter(name);
  EXPECT_NE(f, nullptr) << name;
  return f->apply(in, args);
}
Value S(const char* s) { return Value::string(s); }
std::string show(const Value& v) { return to_display(v); }
}  // namespace

TEST(Filters, Registry) {
  for (const char* n : {"upper", "lower", "trim", "escape", "replace", "length", "int", "join", "first", "last",
                        "reverse", "sort", "default"}) {
    EXPECT_NE(find_filter(n), nullptr) << n;
  }
  EXPECT_EQ(find_filter("title"), nullptr);
  EXPECT_TRUE(find_filter("default")->accepts_undefined);
  EXPECT_FALSE(find_filter("upper")->accepts_undefined);
}

TEST(Filters, CaseAndTrim) {
  EXPECT_EQ(show(apply("upper", S("abC1"))), "ABC1");
  EXPECT_EQ(show(apply("lower", S("AbC1"))), "abc1");
  EXPECT_EQ(show(apply("upper", Value::integer(5))), "5");
  EXPECT_EQ(show(apply("trim", S(" \t\n x y \n "))), "x y");
}

TEST(Filters, Escape) {
  EXPECT_EQ(show(apply("escape", S("<a href=\"x\">&'</a>"))),
            "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;");
  EXPECT_EQ(show(apply("escape", S("&lt;"))), "&amp;lt;");
}

TEST(Filters, Replace) {
  EXPECT_EQ(show(apply("replace", S("aaaa"), {S("aa"), S("b")})), "bb");
  EXPECT_EQ(show(apply("replace", S("a-b"), {S("-"), Value::integer(1)})), "a1b");
  EXPECT_EQ(show(apply("replace", S("xyz"), {S("q"), S("r")})), "xyz");
}

TEST(Filters, Length) {
  EXPECT_EQ(apply("length", S("h\xc3\xa9llo")).as_int(), 5);
  EXPECT_EQ(apply("length", parse_json("[1,2,3]")).as_int(), 3);
  EXPECT_EQ(apply("length", parse_json(R"({"a":1})")).as_int(), 1);
  EXPECT_THROW(apply("length", Value::integer(3)), Error);
}

TEST(Filters, Int) {
  EXPECT_EQ(apply("int", Value::real(-3.9)).as_int(), -3);
  EXPECT_EQ(apply("int", Value::boolean(true)).as_int(), 1);
  EXPECT_EQ(apply("int", S(" 42 ")).as_int(), 42);
  EXPECT_EQ(apply("int", S("+7")).as_int(), 7);
  EXPECT_EQ(apply("int", S("-3.99")).as_int(), -3);
  EXPECT_EQ(apply("int", S("1e3")).as_int(), 1000);
  EXPECT_EQ(apply("int", S(".5")).as_int(), 0);
  EXPECT_EQ(apply("int", S("abc")).as_int(), 0);
  EXPECT_EQ(apply("int", S("")).as_int(), 0);
  EXPECT_EQ(apply("int", S("1e")).as_int(), 0);
  EXPECT_EQ(apply("int", Value::none()).as_int(), 0);
  EXPECT_EQ(apply("int", parse_json("[1]")).as_int(), 0);
}

TEST(Filters, Join) {
  EXPECT_EQ(show(apply("join", parse_json(R"([1, "a", true, null])"), {S(",")})), "1,a,True,None");
  EXPECT_EQ(show(apply("join", parse_json("[1,2]"))), "12");
  EXPECT_EQ(show(apply("join", S("abc"), {S("-")})), "a-b-c");
  EXPECT_EQ(show(apply("join", parse_json(R"({"x":1,"y":2})"), {S("+")})), "x+y");
  EXPECT_THROW(apply("join", Value::integer(1)), Error);
}

TEST(Filters, FirstLastReverse) {
  EXPECT_EQ(apply("first", parse_json("[7,8]")).as_int(), 7);
  EXPECT_EQ(apply("last", parse_json("[7,8]")).as_int(), 8);
  EXPECT_TRUE(apply("first", parse_json("[]")).is_undefined());
  EXPECT_TRUE(apply("last", S("")).is_undefined());
  EXPECT_EQ(apply("first", S("\xc3\xa9x")).as_string(), "\xc3\xa9");
  EXPECT_EQ(apply("last", parse_json(R"({"a":1,"b":2})")).as_string(), "b");
  EXPECT_EQ(show(apply("reverse", S("ab\xc3\xa9"))), "\xc3\xa9" "ba");
  EXPECT_EQ(show(apply("reverse", parse_json("[1,2,3]"))), "[3, 2, 1]");
  EXPECT_THROW(apply("reverse", Value::none()), Error);
}

TEST(Filters, Sort) {
  EXPECT_EQ(show(apply("sort", parse_json("[3, 1.5, 2, true]"))), "[True, 1.5, 2, 3]");
  EXPECT_EQ(show(apply("sort", parse_json(R"(["b", "A", "a", "B"])"))), "['A', 'a', 'b', 'B']");
  EXPECT_EQ(show(apply("sort", parse_json("[]"))), "[]");
  EXPECT_EQ(show(apply("sort", parse_json(R"({"b":1,"a":2})"))), "['a', 'b']");
  EXPECT_THROW(apply("sort", parse_json(R"([1, "a"])")), Error);
}

TEST(Filters, SortIsStable) {
  // Equal keys (case-insensitively) keep their original relative order.
  EXPECT_EQ(show(apply("sort", parse_json(R"(["b", "B", "a", "b", "A"])"))), "['a', 'A', 'b', 'B', 'b']");
}

TEST(Filters, Default) {
  EXPECT_EQ(show(apply("default", Value())), "");
  EXPECT_EQ(show(apply("default", Value(), {S("d")})), "d");
  EXPECT_EQ(apply("default", Value::integer(0), {S("d")}).as_int(), 0);
  EXPECT_TRUE(apply("default", Value::none(), {S("d")}).is_none());
}
