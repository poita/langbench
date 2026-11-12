#include <gtest/gtest.h>

#include "langvm/diagnostic.h"
#include "lexer.h"
#include "source.h"
#include "utf8.h"

using namespace langvm;

namespace {

std::vector<Token> lexStr(const std::string& s) { return lex(decodeUtf8(s)); }

std::string lexError(const std::string& s) {
  try {
    lexStr(s);
  } catch (const CompileError& e) {
    return e.diagnostic().toString();
  }
  return "";
}

}  // namespace

TEST(Lexer, KeywordsIdentifiersAndWildcard) {
  auto t = lexStr("fn foo _ _x self Self");
  ASSERT_EQ(t.size(), 7u);
  EXPECT_EQ(t[0].kind, Tok::KwFn);
  EXPECT_EQ(t[1].kind, Tok::Ident);
  EXPECT_EQ(t[1].text, "foo");
  EXPECT_EQ(t[2].kind, Tok::Underscore);
  EXPECT_EQ(t[3].kind, Tok::Ident);
  EXPECT_EQ(t[4].kind, Tok::KwSelf);
  EXPECT_EQ(t[5].kind, Tok::Ident);  // Self is an ordinary identifier token
}

TEST(Lexer, IntegerLiterals) {
  auto t = lexStr("0 007 1_000 0xFF 0b101 0x7fffffffffffffff");
  EXPECT_EQ(t[0].intVal, 0);
  EXPECT_EQ(t[1].intVal, 7);
  EXPECT_EQ(t[2].intVal, 1000);
  EXPECT_EQ(t[3].intVal, 255);
  EXPECT_EQ(t[4].intVal, 5);
  EXPECT_EQ(t[5].intVal, INT64_MAX);
}

TEST(Lexer, IntegerErrors) {
  EXPECT_EQ(lexError("9223372036854775808"), "error: int-range at 1:1");
  EXPECT_EQ(lexError("  0x"), "error: bad-token at 1:3");
  EXPECT_EQ(lexError("0x_1"), "error: bad-token at 1:1");
  EXPECT_EQ(lexError("0b2"), "error: bad-token at 1:1");
}

TEST(Lexer, UppercasePrefixIsIntegerThenIdentifier) {
  auto t = lexStr("0X1");
  EXPECT_EQ(t[0].kind, Tok::Int);
  EXPECT_EQ(t[1].kind, Tok::Ident);
  EXPECT_EQ(t[1].text, "X1");
}

TEST(Lexer, FloatLiterals) {
  auto t = lexStr("1.5 1_.5 1e3 1e1_0 2.5E-1");
  EXPECT_EQ(t[0].kind, Tok::Float);
  EXPECT_DOUBLE_EQ(t[0].floatVal, 1.5);
  EXPECT_DOUBLE_EQ(t[1].floatVal, 1.5);
  EXPECT_DOUBLE_EQ(t[2].floatVal, 1000.0);
  EXPECT_DOUBLE_EQ(t[3].floatVal, 1e10);
  EXPECT_DOUBLE_EQ(t[4].floatVal, 0.25);
}

TEST(Lexer, NumberBoundaries) {
  auto range = lexStr("0..3");
  EXPECT_EQ(range[0].kind, Tok::Int);
  EXPECT_EQ(range[1].kind, Tok::DotDot);
  EXPECT_EQ(range[2].kind, Tok::Int);
  auto trailingDot = lexStr("1.");
  EXPECT_EQ(trailingDot[0].kind, Tok::Int);
  EXPECT_EQ(trailingDot[1].kind, Tok::Dot);
  auto bareE = lexStr("1e");
  EXPECT_EQ(bareE[0].kind, Tok::Int);
  EXPECT_EQ(bareE[1].text, "e");
  auto underscoreExp = lexStr("1e_5");
  EXPECT_EQ(underscoreExp[0].kind, Tok::Int);
  EXPECT_EQ(underscoreExp[1].text, "e_5");
}

TEST(Lexer, StringAndCharEscapes) {
  auto t = lexStr(R"("a\n\t\\\"\u{1F600}" '\'' 'x')");
  EXPECT_EQ(t[0].strVal, std::u32string(U"a\n\t\\\"\U0001F600"));
  EXPECT_EQ(t[1].intVal, '\'');
  EXPECT_EQ(t[2].intVal, 'x');
}

TEST(Lexer, LiteralErrors) {
  EXPECT_EQ(lexError("\"abc"), "error: unterminated at 1:1");
  EXPECT_EQ(lexError("\"ab\\q"), "error: bad-escape at 1:4");
  EXPECT_EQ(lexError("'ab'"), "error: unterminated at 1:1");
  EXPECT_EQ(lexError("'\\q'"), "error: bad-escape at 1:2");
  EXPECT_EQ(lexError("''"), "error: unterminated at 1:1");
  EXPECT_EQ(lexError("\"\\u{D800}\""), "error: bad-escape at 1:2");
  EXPECT_EQ(lexError("\"\\u{1234567}\""), "error: bad-escape at 1:2");
}

TEST(Lexer, NestedBlockComments) {
  auto t = lexStr("a /* x /* y */ z */ b // tail\nc");
  ASSERT_EQ(t.size(), 4u);
  EXPECT_EQ(t[2].text, "c");
  EXPECT_EQ(t[2].pos.line, 2);
  EXPECT_EQ(lexError("  /* /* */"), "error: unterminated at 1:3");
}

TEST(Lexer, OperatorsAreLongestMatch) {
  auto t = lexStr("#[ :: .. -> == != <= >= && || << >> ++ | = < >");
  std::vector<Tok> want = {Tok::HashBracket, Tok::ColonColon, Tok::DotDot, Tok::Arrow, Tok::EqEq, Tok::NotEq,
                           Tok::LessEq, Tok::GreaterEq, Tok::AndAnd, Tok::OrOr, Tok::Shl, Tok::Shr,
                           Tok::PlusPlus, Tok::Pipe, Tok::Assign, Tok::Less, Tok::Greater, Tok::Eof};
  ASSERT_EQ(t.size(), want.size());
  for (size_t i = 0; i < want.size(); ++i) EXPECT_EQ(t[i].kind, want[i]) << i;
}

TEST(Lexer, BadTokens) {
  EXPECT_EQ(lexError("#x"), "error: bad-token at 1:1");
  EXPECT_EQ(lexError("a @ b"), "error: bad-token at 1:3");
  EXPECT_EQ(lexError("h\xC3\xA9llo"), "error: bad-token at 1:2");  // non-ASCII identifier char
  EXPECT_EQ(lexError(std::string(201, 'a')), "error: bad-token at 1:1");
}

TEST(Lexer, PositionsCountScalarValues) {
  auto t = lexStr("\"\xC3\xA9\" x");
  EXPECT_EQ(t[1].pos.col, 5);
  auto eof = lexStr("a\nbc");
  EXPECT_EQ(eof.back().kind, Tok::Eof);
  EXPECT_EQ(eof.back().pos.line, 2);
  EXPECT_EQ(eof.back().pos.col, 3);
}

TEST(ModuleSplitting, HeadersAndBodies) {
  auto mods = splitModules("@module a\nx\r\ny\n@module b\n");
  ASSERT_EQ(mods.size(), 2u);
  EXPECT_EQ(mods[0].name, "a");
  EXPECT_EQ(mods[0].text, U"x\ny");
  EXPECT_EQ(mods[1].name, "b");
  EXPECT_TRUE(mods[1].text.empty());
}

TEST(ModuleSplitting, Errors) {
  auto err = [](const std::string& s) {
    try {
      splitModules(s);
    } catch (const CompileError& e) {
      return e.diagnostic().toString();
    }
    return std::string();
  };
  EXPECT_EQ(err(""), "error: bad-module at 1:1");
  EXPECT_EQ(err("fn main() {}"), "error: bad-module at 1:1");
  EXPECT_EQ(err("@module a\n@module  b\n"), "error: bad-module at 2:1");
  EXPECT_EQ(err("@module a \n"), "error: bad-module at 1:1");
  EXPECT_EQ(err("@module fn\n"), "error: bad-module at 1:1");
  EXPECT_EQ(err("@module a\n\n@module b\n@module a\n"), "error: dup-module at 4:1");
}
