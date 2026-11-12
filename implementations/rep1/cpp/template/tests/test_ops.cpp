#include <gtest/gtest.h>

#include "jinjalite/error.hpp"
#include "jinjalite/format.hpp"
#include "jinjalite/json.hpp"
#include "jinjalite/ops.hpp"

using namespace jinjalite;

namespace {
Value I(int64_t i) { return Value::integer(i); }
Value F(double d) { return Value::real(d); }
Value S(const char* s) { return Value::string(s); }

template <typename Fn>
void expect_error(ErrorKind kind, Fn fn) {
  try {
    fn();
    FAIL() << "expected an error";
  } catch (const Error& e) {
    EXPECT_EQ(e.kind(), kind);
  }
}
}  // namespace

TEST(Ops, Truthiness) {
  EXPECT_FALSE(is_truthy(Value::none()));
  EXPECT_FALSE(is_truthy(I(0)));
  EXPECT_FALSE(is_truthy(F(0.0)));
  EXPECT_FALSE(is_truthy(S("")));
  EXPECT_FALSE(is_truthy(parse_json("[]")));
  EXPECT_FALSE(is_truthy(parse_json("{}")));
  EXPECT_TRUE(is_truthy(S("0")));
  EXPECT_TRUE(is_truthy(parse_json("[0]")));
  expect_error(ErrorKind::Undefined, [] { is_truthy(Value()); });
}

TEST(Ops, IntegerArithmeticStaysExact) {
  EXPECT_EQ(binary_op(BinaryOp::Add, I(1), I(2)).as_int(), 3);
  EXPECT_EQ(binary_op(BinaryOp::Mul, I(6), Value::boolean(true)).as_int(), 6);
  EXPECT_EQ(binary_op(BinaryOp::Pow, I(2), I(62)).as_int(), int64_t{1} << 62);
  EXPECT_TRUE(binary_op(BinaryOp::Add, I(1), F(1)).is_float());
}

TEST(Ops, DivisionAndModulo) {
  EXPECT_EQ(to_display(binary_op(BinaryOp::Div, I(6), I(3))), "2.0");
  EXPECT_EQ(binary_op(BinaryOp::FloorDiv, I(-7), I(2)).as_int(), -4);
  EXPECT_EQ(to_display(binary_op(BinaryOp::FloorDiv, F(7.0), I(2))), "3.0");
  EXPECT_EQ(binary_op(BinaryOp::Mod, I(-7), I(3)).as_int(), 2);
  EXPECT_EQ(binary_op(BinaryOp::Mod, I(7), I(-3)).as_int(), -2);
  EXPECT_EQ(to_display(binary_op(BinaryOp::Mod, F(-7.5), I(2))), "0.5");
  expect_error(ErrorKind::Type, [] { binary_op(BinaryOp::Div, I(1), I(0)); });
  expect_error(ErrorKind::Type, [] { binary_op(BinaryOp::FloorDiv, I(1), F(0.0)); });
  expect_error(ErrorKind::Type, [] { binary_op(BinaryOp::Mod, I(1), I(0)); });
}

TEST(Ops, Power) {
  EXPECT_EQ(binary_op(BinaryOp::Pow, I(3), I(4)).as_int(), 81);
  EXPECT_EQ(to_display(binary_op(BinaryOp::Pow, I(2), I(-1))), "0.5");
  EXPECT_EQ(to_display(binary_op(BinaryOp::Pow, F(2.0), I(3))), "8.0");
  expect_error(ErrorKind::Type, [] { binary_op(BinaryOp::Pow, I(0), I(-1)); });
}

TEST(Ops, StringAndListOperators) {
  EXPECT_EQ(binary_op(BinaryOp::Add, S("a"), S("b")).as_string(), "ab");
  EXPECT_EQ(binary_op(BinaryOp::Mul, S("ab"), I(3)).as_string(), "ababab");
  EXPECT_EQ(binary_op(BinaryOp::Mul, I(2), S("x")).as_string(), "xx");
  EXPECT_EQ(binary_op(BinaryOp::Mul, S("ab"), I(-1)).as_string(), "");
  EXPECT_EQ(to_display(binary_op(BinaryOp::Add, parse_json("[1]"), parse_json("[2]"))), "[1, 2]");
  EXPECT_EQ(binary_op(BinaryOp::Concat, I(1), Value::boolean(true)).as_string(), "1True");
  expect_error(ErrorKind::Type, [] { binary_op(BinaryOp::Add, I(1), S("a")); });
  expect_error(ErrorKind::Type, [] { binary_op(BinaryOp::Sub, S("a"), S("a")); });
  expect_error(ErrorKind::Undefined, [] { binary_op(BinaryOp::Add, Value(), S("a")); });
}

TEST(Ops, Equality) {
  EXPECT_TRUE(values_equal(I(1), F(1.0)));
  EXPECT_TRUE(values_equal(Value::boolean(true), I(1)));
  EXPECT_FALSE(values_equal(I(1), S("1")));
  EXPECT_FALSE(values_equal(Value::none(), I(0)));
  EXPECT_TRUE(values_equal(Value::none(), Value::none()));
  EXPECT_TRUE(values_equal(parse_json("[1, [2]]"), parse_json("[1.0, [2]]")));
  EXPECT_FALSE(values_equal(parse_json("[1]"), parse_json("[1, 2]")));
  EXPECT_TRUE(values_equal(parse_json(R"({"a":1,"b":2})"), parse_json(R"({"b":2,"a":1})")));
  EXPECT_FALSE(values_equal(parse_json(R"({"a":1})"), parse_json(R"({"a":2})")));
}

TEST(Ops, Ordering) {
  EXPECT_TRUE(compare(CompareOp::Lt, I(1), F(1.5)));
  EXPECT_TRUE(compare(CompareOp::Le, I(2), I(2)));
  EXPECT_TRUE(compare(CompareOp::Gt, S("b"), S("a")));
  EXPECT_TRUE(compare(CompareOp::Lt, S("ab"), S("abc")));
  EXPECT_TRUE(compare(CompareOp::Ge, S("Z"), S("A")));
  expect_error(ErrorKind::Type, [] { compare(CompareOp::Lt, I(1), S("a")); });
  expect_error(ErrorKind::Type, [] { compare(CompareOp::Lt, parse_json("[1]"), parse_json("[2]")); });
  expect_error(ErrorKind::Undefined, [] { compare(CompareOp::Eq, Value(), I(1)); });
}

TEST(Ops, Containment) {
  EXPECT_TRUE(compare(CompareOp::In, S("bc"), S("abcd")));
  EXPECT_TRUE(compare(CompareOp::In, S(""), S("abc")));
  EXPECT_TRUE(compare(CompareOp::In, S("a"), parse_json(R"({"a": 1})")));
  EXPECT_FALSE(compare(CompareOp::In, I(1), parse_json(R"({"a": 1})")));
  EXPECT_TRUE(compare(CompareOp::In, I(2), parse_json("[1, 2.0]")));
  EXPECT_TRUE(compare(CompareOp::NotIn, I(3), parse_json("[1, 2]")));
  expect_error(ErrorKind::Type, [] { compare(CompareOp::In, I(1), S("abc")); });
  expect_error(ErrorKind::Type, [] { compare(CompareOp::In, I(1), I(2)); });
}

TEST(Ops, GetItem) {
  Value d = parse_json(R"({"a": 1})");
  Value l = parse_json("[10, 20, 30]");
  EXPECT_EQ(get_item(d, S("a")).as_int(), 1);
  EXPECT_TRUE(get_item(d, S("b")).is_undefined());
  EXPECT_TRUE(get_item(d, I(0)).is_undefined());
  EXPECT_EQ(get_item(l, I(-1)).as_int(), 30);
  EXPECT_TRUE(get_item(l, I(3)).is_undefined());
  EXPECT_TRUE(get_item(l, I(-4)).is_undefined());
  EXPECT_TRUE(get_item(l, F(1.0)).is_undefined());
  EXPECT_TRUE(get_item(l, S("a")).is_undefined());
  EXPECT_EQ(get_item(l, Value::boolean(true)).as_int(), 20);
  EXPECT_EQ(get_item(S("h\xc3\xa9llo"), I(1)).as_string(), "\xc3\xa9");
  EXPECT_EQ(get_item(S("abc"), I(-1)).as_string(), "c");
  EXPECT_TRUE(get_item(Value::none(), S("x")).is_undefined());
  EXPECT_TRUE(get_item(I(5), S("x")).is_undefined());
  expect_error(ErrorKind::Undefined, [] { get_item(Value(), S("x")); });
}

TEST(Ops, SequenceView) {
  EXPECT_EQ(sequence_view(parse_json(R"({"x": 1, "y": 2})"))->size(), 2u);
  EXPECT_EQ((*sequence_view(parse_json(R"({"x": 1, "y": 2})")))[1].as_string(), "y");
  EXPECT_EQ(sequence_view(S("h\xc3\xa9"))->size(), 2u);
  expect_error(ErrorKind::Type, [] { sequence_view(I(3)); });
  expect_error(ErrorKind::Type, [] { sequence_view(Value::none()); });
  expect_error(ErrorKind::Undefined, [] { sequence_view(Value()); });
}

TEST(Ops, Negate) {
  EXPECT_EQ(negate(I(3)).as_int(), -3);
  EXPECT_EQ(negate(Value::boolean(true)).as_int(), -1);
  EXPECT_EQ(negate(F(1.5)).as_float(), -1.5);
  expect_error(ErrorKind::Type, [] { negate(S("a")); });
}
