#include <gtest/gtest.h>

#include <string>

#include "protowire/codec.hpp"
#include "protowire/error.hpp"

using namespace protowire;

namespace {

const Schema& schema() {
  static const Schema s = Schema::parse(R"(
    message Inner { sint32 v = 1; }
    message T { int32 a = 1; string s = 2; bytes y = 3; bool b = 4; repeated int32 r = 5; Inner d = 6;
                repeated string rs = 7; uint32 u = 8; repeated Inner ri = 9; int64 l = 10; }
  )");
  return s;
}

const MessageDescriptor& T() { return *schema().findMessage("T"); }

bool accepts(std::string_view text) {
  try {
    parseMessage(T(), text);
    return true;
  } catch (const TextError&) {
    return false;
  }
}

std::string canonical(std::string_view text) { return formatMessage(parseMessage(T(), text)); }

}  // namespace

TEST(TextParse, AcceptsRelaxedSpacing) {
  EXPECT_TRUE(accepts("{}"));
  EXPECT_TRUE(accepts("  {  }  "));
  EXPECT_TRUE(accepts("{a:1,r:[1,2]}"));
  EXPECT_TRUE(accepts("{ a : 1 , r : [ 1 , 2 ] }"));
  EXPECT_TRUE(accepts("{r:[]}"));
  EXPECT_TRUE(accepts("{d:{}}"));
}

TEST(TextParse, RejectsBadStructure) {
  EXPECT_FALSE(accepts(""));
  EXPECT_FALSE(accepts("   "));
  EXPECT_FALSE(accepts("{"));
  EXPECT_FALSE(accepts("{a: 1"));
  EXPECT_FALSE(accepts("{a: 1,}"));
  EXPECT_FALSE(accepts("{a: 1 b: 2}"));
  EXPECT_FALSE(accepts("{a 1}"));
  EXPECT_FALSE(accepts("{a: 1} x"));
  EXPECT_FALSE(accepts("{a: 1}}"));
  EXPECT_FALSE(accepts("{,}"));
  EXPECT_FALSE(accepts("{r: [1,]}"));
  EXPECT_FALSE(accepts("{r: [1 2]}"));
  EXPECT_FALSE(accepts("{r: [1, 2}"));
  EXPECT_FALSE(accepts("\t{}"));
  EXPECT_FALSE(accepts("{\ta: 1}"));
}

TEST(TextParse, RejectsNamesAndKinds) {
  EXPECT_FALSE(accepts("{zz: 1}"));
  EXPECT_FALSE(accepts("{a: 1, a: 2}"));
  EXPECT_FALSE(accepts("{a: [1]}"));
  EXPECT_FALSE(accepts("{r: 1}"));
  EXPECT_FALSE(accepts(R"({a: "1"})"));
  EXPECT_FALSE(accepts("{a: {}}"));
  EXPECT_FALSE(accepts("{s: 1}"));
  EXPECT_FALSE(accepts("{b: 1}"));
  EXPECT_FALSE(accepts("{b: 0}"));
  EXPECT_FALSE(accepts(R"({b: "true"})"));
  EXPECT_FALSE(accepts("{b: True}"));
  EXPECT_FALSE(accepts("{b: tr ue}"));
  EXPECT_FALSE(accepts("{d: 1}"));
  EXPECT_FALSE(accepts("{d: [{}]}"));
  EXPECT_FALSE(accepts(R"({y: "00"})"));
  EXPECT_FALSE(accepts(R"({s: x"00"})"));
}

TEST(TextParse, RejectsBadIntegers) {
  EXPECT_FALSE(accepts("{a: -0}"));
  EXPECT_FALSE(accepts("{a: 007}"));
  EXPECT_FALSE(accepts("{a: +5}"));
  EXPECT_FALSE(accepts("{a: 1.0}"));
  EXPECT_FALSE(accepts("{a: - 1}"));
  EXPECT_FALSE(accepts("{a: -}"));
  EXPECT_FALSE(accepts("{a: 1x}"));
  EXPECT_FALSE(accepts("{u: -1}"));
  EXPECT_FALSE(accepts("{u: 4294967296}"));
  EXPECT_TRUE(accepts("{u: 4294967295}"));
  EXPECT_TRUE(accepts("{l: -9223372036854775808}"));
  EXPECT_FALSE(accepts("{l: -9223372036854775809}"));
  EXPECT_TRUE(accepts("{a: 0}"));
}

TEST(TextParse, StringEscapes) {
  EXPECT_EQ(canonical(R"({s: "a\"b\\c\nd\re\tf"})"), R"({s: "a\"b\\c\nd\re\tf"})");
  EXPECT_EQ(canonical(R"({s: "\xc3\xa9"})"), "{s: \"\xc3\xa9\"}");
  EXPECT_EQ(canonical(R"({s: "\x41\x4A"})"), R"({s: "AJ"})");
  EXPECT_EQ(canonical("{s: \"\x7f\"}"), R"({s: "\x7f"})");
  EXPECT_EQ(canonical(R"({s: "\x00\x1f"})"), R"({s: "\x00\x1f"})");
  EXPECT_FALSE(accepts(R"({s: "\q"})"));
  EXPECT_FALSE(accepts(R"({s: "\x4"})"));
  EXPECT_FALSE(accepts(R"({s: "\xzz"})"));
  EXPECT_FALSE(accepts(R"({s: "\xc3"})"));  // lone lead byte: invalid UTF-8
  EXPECT_FALSE(accepts("{s: \"a\tb\"}"));   // raw TAB
  EXPECT_FALSE(accepts("{s: \"a\nb\"}"));
  EXPECT_FALSE(accepts(R"({s: "abc})"));
  EXPECT_FALSE(accepts(R"({s: "\)"));
  EXPECT_TRUE(accepts("{s: \"h\xc3\xa9llo \xf0\x9f\x98\x80\"}"));
  EXPECT_TRUE(accepts("{s: \"has spaces  in it\"}"));
}

TEST(TextParse, BytesLiterals) {
  EXPECT_TRUE(accepts(R"({y: x""})"));
  EXPECT_TRUE(accepts(R"({y: x"00ff"})"));
  EXPECT_FALSE(accepts(R"({y: x"0"})"));
  EXPECT_FALSE(accepts(R"({y: x"00FF"})"));
  EXPECT_FALSE(accepts(R"({y: x"zz"})"));
  EXPECT_FALSE(accepts(R"({y: x "00"})"));
  EXPECT_FALSE(accepts(R"({y: x"00)"));
}

TEST(TextFormat, CanonicalOutput) {
  EXPECT_EQ(canonical("{}"), "{}");
  EXPECT_EQ(canonical("{ r : [ ] , a : 0 , s : \"\" , y : x\"\" , b : false }"), "{}");
  EXPECT_EQ(canonical("{d:{},a:-5,b:true,rs:[\"\",\"q\"],y:x\"0aff\",r:[0,1,-1]}"),
            R"({a: -5, y: x"0aff", b: true, r: [0, 1, -1], d: {}, rs: ["", "q"]})");
  EXPECT_EQ(canonical("{ri:[{v:1},{}]}"), "{ri: [{v: 1}, {}]}");
}

TEST(TextFormat, ParseDepthLimit) {
  Schema s = Schema::parse("message N { N n = 1; }");
  std::string text;
  for (int i = 0; i < 5000; ++i) text += "{n:";
  text += "{}";
  for (int i = 0; i < 5000; ++i) text += "}";
  EXPECT_THROW(parseMessage(*s.findMessage("N"), text), TextError);
}
