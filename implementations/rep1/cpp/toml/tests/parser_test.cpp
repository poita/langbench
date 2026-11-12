#include <gtest/gtest.h>

#include <string>

#include "toml/parser.hpp"
#include "toml/tagged_json.hpp"

using toml::ParseError;
using toml::Value;

namespace {
std::string json(std::string_view doc) { return toml::to_tagged_json(toml::parse(doc)); }
void expect_invalid(std::string_view doc) {
  EXPECT_THROW(toml::parse(doc), ParseError) << "document: " << doc;
}
void expect_valid(std::string_view doc) {
  EXPECT_NO_THROW(toml::parse(doc)) << "document: " << doc;
}
}  // namespace

TEST(Parser, EmptyDocument) {
  EXPECT_EQ(json(""), "{}");
  EXPECT_EQ(json("\n# just a comment\n   \n"), "{}");
}

TEST(Parser, ScalarTypes) {
  Value v = toml::parse("s = 'x'\ni = 0x10\nf = 1.5\nb = true\nd = 1979-05-27\n");
  EXPECT_EQ(v.find("s")->as_string(), "x");
  EXPECT_EQ(v.find("i")->as_integer(), 16);
  EXPECT_DOUBLE_EQ(v.find("f")->as_float(), 1.5);
  EXPECT_TRUE(v.find("b")->as_bool());
  EXPECT_EQ(v.find("d")->type(), toml::Type::DateLocal);
  EXPECT_THROW(v.find("s")->as_integer(), toml::TypeError);
}

TEST(Parser, WorkedExample) {
  const char* doc =
      "name = \"Tom\"\ndob = 1979-05-27T07:32:00-08:00\n\n[db]\nports = [ 8001, 8002 ]\n"
      "enabled = true\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n";
  EXPECT_EQ(json(doc),
            R"({"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},)"
            R"({"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},)"
            R"("fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],)"
            R"("name":{"type":"string","value":"Tom"}})");
}

TEST(Parser, ErrorCarriesPosition) {
  try {
    toml::parse("a = 1\nb = \n");
    FAIL() << "expected ParseError";
  } catch (const ParseError& e) {
    EXPECT_EQ(e.line(), 2u);
    EXPECT_GE(e.column(), 1u);
  }
}

// ---- strings -----------------------------------------------------------------

TEST(Strings, BasicEscapes) {
  Value v = toml::parse(R"(a = "q\"\\\b\t\n\f\r \u00e9 \U0001F600 \u0000")");
  EXPECT_EQ(v.find("a")->as_string(), std::string("q\"\\\b\t\n\f\r \xC3\xA9 \xF0\x9F\x98\x80 ", 17) + std::string(1, '\0'));
}

TEST(Strings, BadEscapes) {
  expect_invalid(R"(a = "\x")");
  expect_invalid(R"(a = "\u12")");
  expect_invalid(R"(a = "\uD800")");
  expect_invalid(R"(a = "\U00110000")");
  expect_invalid(R"(a = "\ ")");
  expect_invalid("a = \"abc");
  expect_invalid("a = \"a\nb\"");
  expect_invalid(std::string("a = \"a\x01") + "\"");
  expect_invalid("a = \"a\x7F\"");
}

TEST(Strings, Literal) {
  EXPECT_EQ(toml::parse(R"(a = 'C:\path\n')").find("a")->as_string(), R"(C:\path\n)");
  expect_invalid("a = 'x\ny'");
  expect_invalid("a = 'it's'");
}

TEST(Strings, MultilineBasic) {
  EXPECT_EQ(toml::parse("a = \"\"\"\nhi\nthere\"\"\"").find("a")->as_string(), "hi\nthere");
  EXPECT_EQ(toml::parse("a = \"\"\"\r\nhi\r\nthere\"\"\"").find("a")->as_string(), "hi\nthere");
  EXPECT_EQ(toml::parse("a = \"\"\"x \\\n   \n  y\"\"\"").find("a")->as_string(), "x y");
  EXPECT_EQ(toml::parse("a = \"\"\"x \\  \r\n y\"\"\"").find("a")->as_string(), "x y");
  EXPECT_EQ(toml::parse("a = \"\"\"\"quoted\"\"\"\"\"").find("a")->as_string(), "\"quoted\"\"");
  EXPECT_EQ(toml::parse("a = \"\"\"a\"\"b\"\"\"").find("a")->as_string(), "a\"\"b");
  expect_invalid("a = \"\"\"x\"\"\"\"\"\"");  // six quotes in a row
  expect_invalid("a = \"\"\"x \\ y\"\"\"");   // backslash then non-newline whitespace
  expect_invalid("a = \"\"\"x\ry\"\"\"");     // lone CR
}

TEST(Strings, MultilineLiteral) {
  EXPECT_EQ(toml::parse("a = '''\nraw \\n\n'''").find("a")->as_string(), "raw \\n\n");
  EXPECT_EQ(toml::parse("a = ''''x'''''").find("a")->as_string(), "'x''");
  expect_invalid("a = '''x''''''");
  expect_invalid("a = '''x");
}

// ---- numbers and dates ----------------------------------------------------------

TEST(Values, NumbersInDocuments) {
  EXPECT_EQ(json("a = 1_000"), R"({"a":{"type":"integer","value":"1000"}})");
  expect_invalid("a = 01");
  expect_invalid("a = 1__0");
  expect_invalid("a = .5");
  expect_invalid("a = 5.");
  expect_invalid("a = 0xFFFFFFFFFFFFFFFF");
  expect_invalid("a = 1e");
  expect_invalid("a = +inf1");
  expect_invalid("a = True");
  expect_invalid("a = ");
  expect_invalid("a = # c\n");
}

TEST(Values, DateWithSpaceSeparator) {
  EXPECT_EQ(json("d = 1979-05-27 # comment"), R"({"d":{"type":"date-local","value":"1979-05-27"}})");
  EXPECT_EQ(json("d = 1979-05-27 07:32:00"),
            R"({"d":{"type":"datetime-local","value":"1979-05-27T07:32:00"}})");
  expect_invalid("d = 1979-05-27 07:32");
  expect_invalid("d = 07:32:00Z");
}

// ---- keys ----------------------------------------------------------------------

TEST(Keys, BareQuotedAndDotted) {
  Value v = toml::parse("a.b . \"c d\" = 1\n'x' = 2");
  EXPECT_EQ(v.find("a")->find("b")->find("c d")->as_integer(), 1);
  EXPECT_EQ(v.find("x")->as_integer(), 2);
}

TEST(Keys, EmptyAndNumericKeys) {
  EXPECT_EQ(json("\"\" = 1\n1234 = 2"),
            R"({"":{"type":"integer","value":"1"},"1234":{"type":"integer","value":"2"}})");
}

TEST(Keys, Invalid) {
  expect_invalid("= 1");
  expect_invalid("a b = 1");
  expect_invalid("a. = 1");
  expect_invalid("\"\"\"a\"\"\" = 1");
  expect_invalid("a = 1 b = 2");
  expect_invalid("a = 1\na = 2");
  expect_invalid("a = 1\n\"a\" = 2");
  expect_invalid("é = 1");
}

TEST(Keys, SortedByCodePoint) {
  EXPECT_EQ(json("\"\xC3\xA9\" = 1\na = 1\nA = 1\n\"\" = 1"),
            R"({"":{"type":"integer","value":"1"},"A":{"type":"integer","value":"1"},)"
            R"("a":{"type":"integer","value":"1"},"é":{"type":"integer","value":"1"}})");
}

// ---- arrays and inline tables --------------------------------------------------

TEST(Arrays, Forms) {
  EXPECT_EQ(json("a = [ ]"), R"({"a":[]})");
  EXPECT_EQ(json("a = [1, 'x', [true],]"),
            R"({"a":[{"type":"integer","value":"1"},{"type":"string","value":"x"},[{"type":"bool","value":"true"}]]})");
  EXPECT_EQ(json("a = [\n  1, # one\n  2\n  # end\n]"),
            R"({"a":[{"type":"integer","value":"1"},{"type":"integer","value":"2"}]})");
  expect_invalid("a = [,]");
  expect_invalid("a = [1,,2]");
  expect_invalid("a = [1 2]");
  expect_invalid("a = [1");
}

TEST(InlineTables, Forms) {
  EXPECT_EQ(json("a = {}"), R"({"a":{}})");
  EXPECT_EQ(json("a = { b.c = 1, d = {e = 2} }"),
            R"({"a":{"b":{"c":{"type":"integer","value":"1"}},"d":{"e":{"type":"integer","value":"2"}}}})");
  EXPECT_NO_THROW(toml::parse("a = { b = [\n1,\n2\n]}"));
  expect_invalid("a = {b = 1,}");
  expect_invalid("a = {\nb = 1}");
  expect_invalid("a = {b = 1\n}");
  expect_invalid("a = {b = 1, b = 2}");
  expect_invalid("a = {b = 1, b.c = 2}");
  expect_invalid("a = {b = 1");
  expect_invalid("a = [{b = 1,\nc = 2}]");
}

TEST(InlineTables, AreClosed) {
  expect_invalid("a = {b = 1}\n[a]");
  expect_invalid("a = {b = {}}\n[a.b]");
  expect_invalid("a = {b = 1}\na.c = 2");
  expect_invalid("a = {b = 1}\n[a.c]");
  expect_invalid("a = {b = {c = 1}}\n[a.b.d]");
  expect_invalid("a = [{b = 1}]\n[[a]]");
  expect_invalid("a = [{b = 1}]\n[a.c]");
}

// ---- tables ---------------------------------------------------------------------

TEST(Tables, HeadersAndImplicitParents) {
  EXPECT_EQ(json("[a.b.c]\nx = 1\n[a]\ny = 2"),
            R"({"a":{"b":{"c":{"x":{"type":"integer","value":"1"}}},"y":{"type":"integer","value":"2"}}})");
  expect_valid("[ a . b ]\n[ a . c ]");
}

TEST(Tables, Redefinition) {
  expect_invalid("[a]\n[a]");
  expect_invalid("a = 1\n[a]");
  expect_invalid("[a.b]\n[a.b]");
  expect_invalid("[a]\nb.c = 1\n[a.b]");
  expect_invalid("a.b = 1\n[a]");
  expect_invalid("[a]\nb = 1\n[a.b]");
  expect_invalid("a = []\n[a]");
  expect_invalid("a = [1]\n[[a]]");
}

TEST(Tables, DottedKeys) {
  expect_valid("a.b = 1\na.c = 2");
  expect_valid("[x]\na.b = 1\na.c = 2");
  expect_valid("[fruit]\napple.color = \"red\"\n[fruit.apple.texture]\nsmooth = true");
  expect_invalid("[fruit]\napple.color = \"red\"\n[fruit.apple]");
  expect_invalid("[a.b]\nx=1\n[a]\nb.y = 2");
  expect_invalid("[a.b.c]\nz = 9\n[a]\nb.c.t = 1");
  expect_invalid("a.b = 1\na.b.c = 2");
}

TEST(Tables, ArraysOfTables) {
  EXPECT_EQ(json("[[a]]\nx = 1\n[a.b]\ny = 2\n[[a]]\nx = 3\n[[a.c]]\nz = 4"),
            R"({"a":[{"b":{"y":{"type":"integer","value":"2"}},"x":{"type":"integer","value":"1"}},)"
            R"({"c":[{"z":{"type":"integer","value":"4"}}],"x":{"type":"integer","value":"3"}}]})");
  expect_valid("[[ a . b ]]");
  expect_invalid("[ [a] ]");
  expect_invalid("[[a] ]");
  expect_invalid("[ [a]]");
  expect_invalid("[[a]]\n[a]");
  expect_invalid("[a]\n[[a]]");
  expect_invalid("a = [{}]\n[[a]]");
}

// ---- document-level checks -------------------------------------------------------

TEST(Document, Encoding) {
  expect_invalid("\xEF\xBB\xBF" "a = 1");
  expect_invalid("a = \"\xFF\"");
  expect_invalid("a = \"\xC3\"");
  expect_invalid(std::string("a = 1\0", 6));
  expect_invalid(std::string("\xFF\xFE", 2));
}

TEST(Document, LineEndings) {
  expect_valid("a = 1\r\nb = 2\r\n");
  expect_valid("a = 1");
  expect_invalid("a = 1\rb = 2");
  expect_invalid("a = 1 # c\rd");
  expect_invalid("a = \"x\ry\"");
  expect_invalid("a = 1\r");
}

TEST(Document, Comments) {
  expect_valid("# a \xC3\xA9 \t comment\na = 1 # trailing");
  expect_invalid("# bad \x01");
  expect_invalid("# bad \x7F");
  expect_invalid("a = 1 # bad \x1F");
}

TEST(Document, UnicodeDigitsAreNotDigits) {
  expect_invalid("a = \xD9\xA1\xD9\xA2");
  expect_invalid("a = \xEF\xBC\x91");
  expect_invalid("a = \xD9\xA1\xD9\xA9\xD9\xA8\xD9\xA7-01-01");
}

TEST(Document, DeepNestingIsHandled) {
  std::string deep = "a = " + std::string(300, '[') + std::string(300, ']');
  EXPECT_NO_THROW(toml::parse(deep));
  std::string absurd = "a = " + std::string(100000, '[');
  EXPECT_THROW(toml::parse(absurd), ParseError);
}
