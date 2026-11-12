#include <gtest/gtest.h>

#include <string>

#include "protowire/codec.hpp"
#include "protowire/error.hpp"

using namespace protowire;

namespace {

const Schema& schema() {
  static const Schema s = Schema::parse(R"(
    message Inner { sint32 v = 1; }
    message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
    message M { uint64 u = 1; sint64 s = 2; fixed32 f = 3; bytes y = 4; repeated bool bs = 5; bool k = 6;
                repeated sfixed64 sf = 7; sint32 z = 8; fixed64 g = 9; repeated Inner items = 10; }
    message N { N next = 1; int32 v = 2; }
  )");
  return s;
}

std::string enc(const char* msg, const char* text) {
  return toHex(encodeFromText(*schema().findMessage(msg), text));
}

}  // namespace

TEST(Encode, SpecExamples) {
  EXPECT_EQ(enc("Outer", R"({a: 1, b: "x", c: [1, 2], d: {v: -5}})"), "08011201781a02010222020809");
  EXPECT_EQ(enc("Outer", "{d: {}, c: [], a: 0}"), "2200");
  EXPECT_EQ(enc("M", R"({k: true, y: x"cafe", s: -128, u: 18446744073709551615})"),
            "08ffffffffffffffffff0110ff01" "2202cafe" "3001");
  EXPECT_THROW(enc("M", "{u: -1}"), TextError);
}

TEST(Encode, EmptyEncodingIsEmpty) {
  EXPECT_EQ(enc("Outer", "{}"), "");
  EXPECT_EQ(enc("Outer", R"({a: 0, b: "", c: []})"), "");
}

TEST(Encode, Integers) {
  EXPECT_EQ(enc("Outer", "{a: -1}"), "08ffffffffffffffffff01");
  EXPECT_EQ(enc("Outer", "{a: 2147483647}"), "08ffffffff07");
  EXPECT_EQ(enc("Outer", "{a: -2147483648}"), "0880808080f8ffffffff01");
  EXPECT_THROW(enc("Outer", "{a: 2147483648}"), TextError);
  EXPECT_THROW(enc("Outer", "{a: -2147483649}"), TextError);
  EXPECT_EQ(enc("M", "{s: -9223372036854775808}"), "10ffffffffffffffffff01");
  EXPECT_THROW(enc("M", "{s: 9223372036854775808}"), TextError);
  EXPECT_THROW(enc("M", "{u: 18446744073709551616}"), TextError);
  EXPECT_EQ(enc("M", "{z: -2147483648}"), "40ffffffff0f");
  EXPECT_EQ(enc("M", "{f: 4294967295}"), "1dffffffff");
  EXPECT_THROW(enc("M", "{f: 4294967296}"), TextError);
  EXPECT_EQ(enc("M", "{g: 1}"), "490100000000000000");
  EXPECT_EQ(enc("M", "{sf: [-1, 2]}"), "3a10ffffffffffffffff0200000000000000");
}

TEST(Encode, FieldsInNumberOrder) {
  EXPECT_EQ(enc("Outer", R"({d: {v: 1}, c: [3], b: "q", a: 7})"), "0807" "120171" "1a0103" "22020802");
}

TEST(Encode, PackedKeepsDefaults) {
  EXPECT_EQ(enc("M", "{bs: [true, false, true]}"), "2a03010001");
  EXPECT_EQ(enc("Outer", "{c: [0, 0]}"), "1a020000");
}

TEST(Encode, RepeatedMessages) {
  EXPECT_EQ(enc("M", "{items: [{v: 1}, {}, {v: -1}]}"), "52020802" "5200" "52020801");
}

TEST(Encode, DeepNestingSizesAreCorrect) {
  std::string text = "{v: 1}";
  for (int i = 0; i < 60; ++i) text = "{next: " + text + "}";
  const auto bytes = encodeFromText(*schema().findMessage("N"), text);
  // Round trip through the decoder.
  EXPECT_EQ(decodeToText(*schema().findMessage("N"), bytes), text);
}

TEST(Encode, LargeLengthPrefix) {
  std::string text = "{b: \"" + std::string(300, 'z') + "\"}";
  const std::string hex = enc("Outer", text.c_str());
  EXPECT_EQ(hex.substr(0, 6), "12ac02");
  EXPECT_EQ(hex.size(), 2u * (3 + 300));
}
