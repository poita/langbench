#include <gtest/gtest.h>

#include "tessera/command.hpp"
#include "tessera/error.hpp"
#include "tessera/lexer.hpp"

using namespace tessera;

static ErrorKind error_of(const std::string& line) {
  try {
    parse_command(line);
  } catch (const Error& e) {
    return e.kind();
  }
  ADD_FAILURE() << "no error for: " << line;
  return ErrorKind::Syntax;
}

static std::string rep(const std::string& s, int n) {
  std::string out;
  for (int i = 0; i < n; ++i) out += s;
  return out;
}

TEST(Lexer, Tokens) {
  auto t = lex("put \"a\\u00e9\" <= -12 foo.bar");
  ASSERT_EQ(t.size(), 7u);
  EXPECT_EQ(t[1].text, "a\xc3\xa9");
  EXPECT_EQ(t[2].text, "<=");
  EXPECT_EQ(t[3].text, "-12");
}

TEST(Lexer, SurrogatePairs) {
  auto t = lex("\"\\ud83d\\ude00\"");
  EXPECT_EQ(t[0].text, "\xf0\x9f\x98\x80");
  EXPECT_FALSE(t[0].bad_utf8);
  EXPECT_TRUE(lex("\"\\ud800\"")[0].bad_utf8);
  EXPECT_TRUE(lex("\"\\ud800x\"")[0].bad_utf8);
  EXPECT_TRUE(lex("\"\\udc00\"")[0].bad_utf8);
  EXPECT_TRUE(lex("\"\\ud800\\u0041\"")[0].bad_utf8);
}

TEST(Parser, LexicalErrorsAreSyntax) {
  for (const char* line : {"", "   ", "\t", "put \"a\" 007", "put \"a\" -0", "put \"a\" +1",
                           "put \"a\" -", "put \"a\" \"abc", "put \"a\" \"\\q\"",
                           "put \"a\" \"\\u00zz\"", "get \"a\" =", "get \"a\" !", "1 2",
                           "put \"a\" \"\ttab\""})
    EXPECT_EQ(error_of(line), ErrorKind::Syntax) << line;
}

TEST(Parser, StageOrder) {
  EXPECT_EQ(error_of("frobnicate \"\\ud800\""), ErrorKind::UnknownCommand);
  EXPECT_EQ(error_of("PUT \"a\" 1"), ErrorKind::UnknownCommand);
  EXPECT_EQ(error_of("put \"\\ud800\" 1"), ErrorKind::BadUtf8);
  EXPECT_EQ(error_of("put 1 \"x\""), ErrorKind::Syntax);
  EXPECT_EQ(error_of("get \"a\" \"\\ud800\""), ErrorKind::Syntax);
  EXPECT_EQ(error_of("put \"a\" 1 99999999999999999999"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("put \"a\" 99999999999999999999"), ErrorKind::IntRange);
  EXPECT_EQ(error_of("put \"a\" -9223372036854775809"), ErrorKind::IntRange);
  EXPECT_NO_THROW(parse_command("put \"a\" -9223372036854775808"));
  EXPECT_NO_THROW(parse_command("put \"a\" 9223372036854775807"));
  EXPECT_EQ(error_of("put \"\" 1"), ErrorKind::BadKey);
  EXPECT_EQ(error_of("put \"" + rep("k", 129) + "\" 1"), ErrorKind::BadKey);
  EXPECT_NO_THROW(parse_command("put \"" + rep("k", 128) + "\" 1"));
}

TEST(Parser, ValueLiterals) {
  EXPECT_EQ(error_of("put \"a\" [1,]"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("put \"a\" {a:1,}"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("put \"a\" {x:1,x}"), ErrorKind::DupField);
  EXPECT_EQ(error_of("put \"a\" {x:1,x 2}"), ErrorKind::DupField);
  EXPECT_EQ(error_of("put \"a\" {\"x\":1,x:2}"), ErrorKind::DupField);
  EXPECT_EQ(error_of("put \"a\" foo"), ErrorKind::Syntax);
  EXPECT_NO_THROW(parse_command("put \"a\" {null:1,true:2}"));
}

TEST(Parser, DepthRules) {
  std::string open = rep("[", 32), close = rep("]", 32);
  EXPECT_NO_THROW(parse_command("put \"a\" " + open + close));
  EXPECT_EQ(error_of("put \"a\" " + open + "1" + close), ErrorKind::Depth);
  EXPECT_EQ(error_of("put \"a\" " + open + "99999999999999999999"), ErrorKind::Depth);
  EXPECT_EQ(error_of("put \"a\" " + open + "\"\\ud800\""), ErrorKind::Depth);
  EXPECT_EQ(error_of("put \"a\" " + open + ","), ErrorKind::Depth);
  EXPECT_EQ(error_of("put \"a\" " + open), ErrorKind::Depth);
  EXPECT_EQ(error_of("put \"a\" " + open + "-"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("put \"a\" " + rep("[", 30) + "{x:[[1]],x:1}"), ErrorKind::Depth);
  EXPECT_EQ(error_of("put \"a\" " + rep("[", 30) + "{x:1,x:[[1]]}"), ErrorKind::DupField);
}

TEST(Parser, Paths) {
  Command c = parse_command("unset \"a\" a . b.c");
  EXPECT_EQ(path_text(c.path), "a.b.c");
  EXPECT_EQ(error_of("unset \"a\" " + rep("x", 31) + " ."), ErrorKind::BadPath);
  EXPECT_EQ(error_of("unset \"a\" a.b.c.d.e.f.g.h.i."), ErrorKind::BadPath);
  EXPECT_EQ(error_of("unset \"a\" a.b.c.d.e.f.g.h."), ErrorKind::Syntax);
  EXPECT_NO_THROW(parse_command("unset \"a\" a.b.c.d.e.f.g.h"));
  EXPECT_EQ(error_of("unset \"a\" abcdefghij.abcdefghij.abcdefghij"), ErrorKind::BadPath);
  EXPECT_EQ(error_of("unset \"a\" abcdefghij.abcdefghij.abcdefghi"), ErrorKind::BadPath);  // 31
  EXPECT_NO_THROW(parse_command("unset \"a\" abcdefghij.abcdefghij.abcdefgh"));          // 30
}

TEST(Parser, ScanOptions) {
  Command c = parse_command("scan limit 3 reverse from \"b\" to \"x\" keys");
  EXPECT_EQ(*c.scan.limit, 3);
  EXPECT_TRUE(c.scan.reverse);
  EXPECT_TRUE(c.scan.keys_only);
  EXPECT_EQ(*c.scan.from, "b");
  EXPECT_EQ(*c.scan.to, "x");
  EXPECT_EQ(error_of("scan keys keys"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("scan limit -1"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("scan limit 2147483648"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("scan limit 99999999999999999999"), ErrorKind::IntRange);
  EXPECT_NO_THROW(parse_command("scan from \"\""));
  EXPECT_NO_THROW(parse_command("scan from \"" + rep("z", 200) + "\""));
}

TEST(Parser, Predicates) {
  EXPECT_NO_THROW(parse_command("find a == 1 and (b < 2 or not(c == 3)) limit 4"));
  EXPECT_NO_THROW(parse_command("find exists a.b and missing c or d >= \"x\" limit 0"));
  // A field called `exists` / `not` is reachable as a path in term position.
  EXPECT_NO_THROW(parse_command("find exists == 1"));
  EXPECT_NO_THROW(parse_command("find not == 1"));
  EXPECT_EQ(error_of("find"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("find a == 1 or"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("find a == 1 foo"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("find a 1"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("find 1 == 1"), ErrorKind::Syntax);
  EXPECT_EQ(error_of("find (a == 1"), ErrorKind::Syntax);
}
