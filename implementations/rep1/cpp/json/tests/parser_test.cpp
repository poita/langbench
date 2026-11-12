#include <gtest/gtest.h>

#include <string>

#include "jsoncanon/parser.hpp"

using namespace jsoncanon;

namespace {
bool valid(std::string_view s) { return try_parse(s).has_value(); }
std::string deep(std::size_t n) { return std::string(n, '[') + std::string(n, ']'); }
}  // namespace

TEST(Parser, ParsesScalars) {
  EXPECT_TRUE(parse("null").is_null());
  EXPECT_TRUE(parse("true").as_bool());
  EXPECT_FALSE(parse(" false ").as_bool());
  EXPECT_EQ(parse("\"hi\"").as_string(), "hi");
  EXPECT_EQ(parse("-12.5e+03").as_number_text(), "-12.5e3");
}

TEST(Parser, ParsesContainers) {
  Value v = parse(R"({"a":[1,2,{"b":null}],"a":true})");
  ASSERT_TRUE(v.is_object());
  ASSERT_EQ(v.as_object().size(), 2u);  // duplicates are kept by the parser
  EXPECT_EQ(v.as_object()[0].key, "a");
  EXPECT_EQ(v.as_object()[0].value.as_array().size(), 3u);
  EXPECT_TRUE(v.as_object()[1].value.as_bool());
}

TEST(Parser, Whitespace) {
  EXPECT_TRUE(valid(" \t\r\n[ \t\r\n1 \t\r\n, 2\n]\n"));
  EXPECT_FALSE(valid(""));
  EXPECT_FALSE(valid(" \n"));
  EXPECT_FALSE(valid("\f1"));
  EXPECT_FALSE(valid("\v1"));
  EXPECT_FALSE(valid(std::string_view("1\0", 2)));
  EXPECT_FALSE(valid("\xC2\xA0" "1"));       // NBSP
  EXPECT_FALSE(valid("\xE2\x80\xA8" "1"));   // U+2028
  EXPECT_FALSE(valid("\xC2\x85" "1"));       // NEL
}

TEST(Parser, RejectsBadUtf8AndBom) {
  EXPECT_FALSE(valid("\xEF\xBB\xBF" "1"));
  EXPECT_FALSE(valid("\"\xC3\""));
  EXPECT_FALSE(valid("\"\xED\xA0\x80\""));
  EXPECT_FALSE(valid("\"\xC0\x80\""));
  EXPECT_TRUE(valid("\"\xEF\xBB\xBF\""));  // BOM char inside a string is fine
}

TEST(Parser, Literals) {
  for (const char* s : {"True", "NaN", "Infinity", "-Infinity", "nul", "nulll", "tru", "FALSE"})
    EXPECT_FALSE(valid(s)) << s;
}

TEST(Parser, Structure) {
  for (const char* s : {"[1,]", "[,1]", "[1 2]", "{\"a\":1,}", "{\"a\" 1}", "{a:1}", "{1:2}",
                        "{'a':1}", "[1] x", "[1][2]", "[", "{", "{\"a\"", "{\"a\":", "[1,",
                        "// c\n1", "/* c */1", "{,}", "[,]", "{\"a\":1 \"b\":2}"})
    EXPECT_FALSE(valid(s)) << s;
  EXPECT_TRUE(valid("[]"));
  EXPECT_TRUE(valid("{}"));
  EXPECT_TRUE(valid("[ ]"));
  EXPECT_TRUE(valid("{ }"));
  EXPECT_TRUE(valid("{ \"a\" : 1 , \"b\" : [ ] }"));
}

TEST(Parser, StringsAndEscapes) {
  EXPECT_EQ(parse(R"("a\"\\\/\b\f\n\r\t")").as_string(), "a\"\\/\b\f\n\r\t");
  EXPECT_EQ(parse(R"("\u0041\u00e9\u00E9")").as_string(), "A\xC3\xA9\xC3\xA9");
  EXPECT_EQ(parse(R"("\ud83d\ude00")").as_string(), "\xF0\x9F\x98\x80");
  EXPECT_EQ(parse(R"("\u0000")").as_string(), std::string("\0", 1));
  EXPECT_EQ(parse("\"\x7f\"").as_string(), "\x7f");
  EXPECT_EQ(parse("\"\xE2\x80\xA8\"").as_string(), "\xE2\x80\xA8");
}

TEST(Parser, BadStrings) {
  for (const char* s : {"\"a\tb\"", "\"a\nb\"", R"("\x")", R"("\U0041")", R"("\'")", R"("\0")",
                        R"("\u12")", R"("\u12G4")", R"("\ud800")", R"("\ud800\u0041")",
                        R"("\ud800\ue000")", R"("\ud800\ud800")", R"("\ud800x")", R"("\udc00")",
                        R"("\ud800\\u")", "\"abc", "[\"\\", "\"\\"})
    EXPECT_FALSE(valid(s)) << s;
  // Fullwidth digit in \u escape.
  EXPECT_FALSE(valid("\"\\u\xEF\xBC\x90" "000\""));
  // Same rule in keys.
  EXPECT_FALSE(valid(R"({"\ud800":1})"));
}

TEST(Parser, ValidityCoversDiscardedDuplicates) {
  EXPECT_FALSE(valid(R"({"a":"\uD800","a":1})"));
  EXPECT_FALSE(valid(R"({"a":[1,],"a":1})"));
  EXPECT_FALSE(valid("{\"a\":" + deep(600) + ",\"a\":1}"));
}

TEST(Parser, NumberGrammar) {
  for (const char* s : {"01", "+1", "-", "1.", ".5", "1e", "1e+", "1E+-5", "1e5e5", "0x1", "- 1",
                        "1 .5", "-01", "00", "1.e3", "--1", "1.5.5", "\xD9\xA2", "\xC2\xB2",
                        "\xEF\xBC\x91"})
    EXPECT_FALSE(valid(s)) << s;
  for (const char* s : {"0", "-0", "0.0", "-0.0e0", "10", "1E5", "1e-7", "123456789012345678901234567890"})
    EXPECT_TRUE(valid(s)) << s;
}

TEST(Parser, NumberTextIsCanonicalised) {
  EXPECT_EQ(parse("1E5").as_number_text(), "1e5");
  EXPECT_EQ(parse("1e+05").as_number_text(), "1e5");
  EXPECT_EQ(parse("1e-007").as_number_text(), "1e-7");
  EXPECT_EQ(parse("1e-0").as_number_text(), "1e0");
  EXPECT_EQ(parse("1E+00").as_number_text(), "1e0");
  EXPECT_EQ(parse("-0.0").as_number_text(), "-0.0");
  EXPECT_EQ(parse("2.5E-000789").as_number_text(), "2.5e-789");
  EXPECT_EQ(parse("1.50").as_number_text(), "1.50");
  EXPECT_EQ(parse("-0").as_number_text(), "-0");
}

TEST(Parser, Depth) {
  EXPECT_TRUE(valid(deep(512)));
  EXPECT_FALSE(valid(deep(513)));
  EXPECT_FALSE(valid(std::string(512, '[') + "{}" + std::string(512, ']')));
  EXPECT_TRUE(valid(std::string(511, '[') + "{}" + std::string(511, ']')));
  EXPECT_FALSE(valid(std::string(100000, '[')));
  EXPECT_TRUE(valid("1"));  // scalars do not count
}

TEST(Parser, CustomMaxDepth) {
  ParseOptions o;
  o.max_depth = 2;
  EXPECT_TRUE(try_parse("[[]]", o).has_value());
  EXPECT_FALSE(try_parse("[[[]]]", o).has_value());
}

TEST(Parser, ErrorReportsOffset) {
  try {
    parse("[1, ?]");
    FAIL() << "expected ParseError";
  } catch (const ParseError& e) {
    EXPECT_EQ(e.offset(), 4u);
  }
}
