#include <gtest/gtest.h>

#include <string>

#include "jsoncanon/parser.hpp"
#include "jsoncanon/serializer.hpp"

using namespace jsoncanon;

namespace {
std::string canon(std::string_view s) { return serialize(parse(s)); }
}  // namespace

TEST(Serializer, Scalars) {
  EXPECT_EQ(canon("null"), "null");
  EXPECT_EQ(canon(" true "), "true");
  EXPECT_EQ(canon("false"), "false");
  EXPECT_EQ(canon("-0"), "-0");
  EXPECT_EQ(canon("123456789012345678901234567890"), "123456789012345678901234567890");
}

TEST(Serializer, StringEscapes) {
  EXPECT_EQ(canon(R"("\"\\\/\b\f\n\r\t")"), R"("\"\\/\b\f\n\r\t")");
  EXPECT_EQ(canon(R"("\u0000\u001F\u001f\u0001")"), R"("\u0000\u001f\u001f\u0001")");
  EXPECT_EQ(canon("\"\x7f\xE2\x80\xA8\""), "\"\x7f\xE2\x80\xA8\"");
  EXPECT_EQ(canon(R"("\u007f\/\u2028\uD83D\uDE00")"), "\"\x7f/\xE2\x80\xA8\xF0\x9F\x98\x80\"");
  EXPECT_EQ(canon(R"("\u0041")"), R"("A")");
}

TEST(Serializer, ArraysAndNoWhitespace) {
  EXPECT_EQ(canon("[ ]"), "[]");
  EXPECT_EQ(canon("{ }"), "{}");
  EXPECT_EQ(canon(" [ 1 , [ 2 , { } ] , \"x\" ] "), R"([1,[2,{}],"x"])");
}

TEST(Serializer, ObjectsAreSortedAndDeduplicated) {
  EXPECT_EQ(canon(R"({"b":1,"a":2})"), R"({"a":2,"b":1})");
  EXPECT_EQ(canon(R"({"a":1,"b":2,"a":3})"), R"({"a":3,"b":2})");
  EXPECT_EQ(canon(R"({"a":1,"\u0061":2,"a":3})"), R"({"a":3})");
  EXPECT_EQ(canon(R"({"x":{"b":1,"a":2},"x":{"c":1}})"), R"({"x":{"c":1}})");
}

TEST(Serializer, Utf16Ordering) {
  EXPECT_EQ(canon(R"({"\uE000":1,"😀":2,"\uFFFF":3,"Z":4})"),
            "{\"Z\":4,\"\xF0\x9F\x98\x80\":2,\"\xEE\x80\x80\":1,\"\xEF\xBF\xBF\":3}");
  EXPECT_EQ(canon(R"({"é":1,"aa":2,"a\u0000":3,"a":4,"Z":5,"":6})"),
            "{\"\":6,\"Z\":5,\"a\":4,\"a\\u0000\":3,\"aa\":2,\"\xC3\xA9\":1}");
}

TEST(Serializer, NumberNormalisation) {
  EXPECT_EQ(canon(R"([1.0,1.50,1E5,1e+05,1e-007,1e-0,1E+00,-0.0,0e0,2.5E-000789])"),
            "[1.0,1.50,1e5,1e5,1e-7,1e0,1e0,-0.0,0e0,2.5e-789]");
}

TEST(Serializer, BuiltValues) {
  Value::Object o;
  o.push_back({"k", Value(Value::Array{Value(1 == 1), Value(nullptr), Value::number("1.5"), Value("s\n")})});
  EXPECT_EQ(serialize(Value(std::move(o))), R"({"k":[true,null,1.5,"s\n"]})");
}

TEST(Serializer, AppendsToExistingBuffer) {
  std::string out = "x=";
  serialize(Value(true), out);
  EXPECT_EQ(out, "x=true");
}

TEST(Serializer, DeepNesting) {
  std::string in = std::string(512, '[') + std::string(512, ']');
  EXPECT_EQ(canon(in), in);
}
