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
                repeated fixed64 f64 = 7; repeated sfixed32 sf = 8; int64 i64 = 9; sint32 z = 10; }
    message P { repeated int32 r = 1; P p = 2; string s = 3; }
    message R { repeated string names = 1; repeated Inner items = 2; }
  )");
  return s;
}

std::string dec(const char* msg, const char* hex) {
  return decodeToText(*schema().findMessage(msg), fromHex(hex));
}
bool fails(const char* msg, const char* hex) {
  try {
    dec(msg, hex);
  } catch (const WireError&) {
    return true;
  }
  return false;
}

}  // namespace

TEST(Decode, SpecExamples) {
  EXPECT_EQ(dec("Outer", "08011201781a02010222020809"), R"({a: 1, b: "x", c: [1, 2], d: {v: -5}})");
  EXPECT_EQ(dec("Outer", "3800"), "{}");
  EXPECT_TRUE(fails("Outer", "08ff"));
  EXPECT_EQ(dec("M", "08ffffffffffffffffff0110ff011dffffffff2202000f2a03010001"),
            R"({u: 18446744073709551615, s: -128, f: 4294967295, y: x"000f", bs: [true, false, true]})");
  EXPECT_EQ(dec("M", "3002"), "{k: true}");
  EXPECT_TRUE(fails("M", "3d000000"));
}

TEST(Decode, MergeAndGroups) {
  EXPECT_EQ(dec("P", "0801080212020803120208041a0322095c"), R"({r: [1, 2], p: {r: [3, 4]}, s: "\"\t\\"})");
  EXPECT_EQ(dec("P", "1b08011c0805"), "{r: [5]}");
  EXPECT_TRUE(fails("P", "1b08011400"));
}

TEST(Decode, EmptyAndLastWins) {
  EXPECT_EQ(dec("Outer", ""), "{}");
  EXPECT_EQ(dec("Outer", "08010802"), "{a: 2}");
  EXPECT_EQ(dec("Outer", "2200"), "{d: {}}");
  EXPECT_EQ(dec("Outer", "0800"), "{}");
}

TEST(Decode, VarintConversions) {
  EXPECT_EQ(dec("M", "48ffffffffffffffffff01"), "{i64: -1}");
  EXPECT_EQ(dec("M", "5001"), "{z: -1}");
  EXPECT_EQ(dec("Outer", "08ffffffffffffffffff01"), "{a: -1}");
  EXPECT_EQ(dec("Outer", "08ffffffff0f"), "{a: -1}");
  EXPECT_EQ(dec("Outer", "088180808000"), "{a: 1}");
  EXPECT_EQ(dec("Outer", "088100"), "{a: 1}");  // non-minimal accepted
  EXPECT_EQ(dec("M", "08808080808080808080" "02"), "{}");
}

TEST(Decode, PackedAndUnpackedMix) {
  EXPECT_EQ(dec("Outer", "1a020102" "1803" "1a0104"), "{c: [1, 2, 3, 4]}");
  EXPECT_EQ(dec("Outer", "1a00"), "{}");
  EXPECT_TRUE(fails("Outer", "1a0180"));  // packed varint ends mid-varint
  EXPECT_EQ(dec("M", "3a10" "0000000000000000" "0100000000000000"), "{f64: [0, 1]}");
  EXPECT_TRUE(fails("M", "3a0400000000"));  // 4 bytes is not a multiple of 8
  EXPECT_EQ(dec("M", "420801000000ffffffff"), "{sf: [1, -1]}");
  EXPECT_EQ(dec("M", "4501000000"), "{sf: [1]}");  // unpacked fixed32
}

TEST(Decode, WrongWireTypeIsSkipped) {
  EXPECT_EQ(dec("Outer", "0d01000000"), "{}");       // a with fixed32
  EXPECT_EQ(dec("Outer", "100108" "02"), "{a: 2}");  // field 2 varint skipped; a read
  EXPECT_EQ(dec("Outer", "0a0161"), "{}");           // a with wire type 2 (singular): skipped
}

TEST(Decode, UnknownFieldsSkipped) {
  EXPECT_EQ(dec("Outer", "f80100"), "{}");
  EXPECT_EQ(dec("Outer", "ba010300ff00" "0801"), "{a: 1}");
  EXPECT_EQ(dec("Outer", "c101" "0000000000000000" "0801"), "{a: 1}");
  EXPECT_EQ(dec("Outer", "ab05" "0801" "0b" "0c" "ac05"), "{}");  // nested groups
}

TEST(Decode, GroupErrors) {
  EXPECT_EQ(dec("Outer", "ab05" "ab05" "ac05" "ac05"), "{}");
  EXPECT_TRUE(fails("Outer", "ab05" "ab05" "ac05"));  // unterminated
  EXPECT_TRUE(fails("Outer", "14"));                  // end-group outside group
  EXPECT_TRUE(fails("Outer", "ab05" "0f"));           // wire type 7 in group
  EXPECT_TRUE(fails("Outer", "ab05" "ac06"));         // mismatched number
  EXPECT_TRUE(fails("Outer", "ab05" "08"));           // truncated in group
}

TEST(Decode, TagAndLengthLimits) {
  EXPECT_TRUE(fails("Outer", "00"));                      // field number 0
  EXPECT_TRUE(fails("Outer", "0e"));                      // wire type 6
  EXPECT_TRUE(fails("Outer", "0f"));                      // wire type 7
  EXPECT_TRUE(fails("Outer", "8080808080" "00" "00"));    // 6-byte tag
  EXPECT_TRUE(fails("Outer", "ffffffff1f00"));            // tag >= 2^32 (5 bytes)
  EXPECT_EQ(dec("Outer", "f8ffffff0f00"), "{}");          // max tag value: field 2^29-1, wt 0
  EXPECT_TRUE(fails("Outer", "12" "8080808080" "00"));    // 6-byte length
  EXPECT_TRUE(fails("Outer", "1202" "61"));               // length exceeds data
  EXPECT_TRUE(fails("Outer", "08" "8080808080808080808000"));  // 11-byte varint
}

TEST(Decode, StringValidation) {
  EXPECT_EQ(dec("Outer", "1202c3a9"), "{b: \"\xc3\xa9\"}");
  EXPECT_TRUE(fails("Outer", "1202c328"));
  EXPECT_TRUE(fails("Outer", "1203eda080"));
  EXPECT_EQ(dec("Outer", "12020001"), R"({b: "\x00\x01"})");
  EXPECT_EQ(dec("Outer", "12027f1f"), R"({b: "\x7f\x1f"})");
  EXPECT_EQ(dec("Outer", "12050a0d09225c"), R"({b: "\n\r\t\"\\"})");
}

TEST(Decode, RepeatedStringsAndMessages) {
  EXPECT_EQ(dec("R", "0a000a0161" "12020801" "1200"), R"({names: ["", "a"], items: [{v: -1}, {}]})");
}

TEST(Decode, ErrorInsideSubMessage) {
  EXPECT_TRUE(fails("Outer", "22020880"));
}
