#include <gtest/gtest.h>

#include "scheme/errors.hpp"
#include "scheme/printer.hpp"
#include "scheme/reader.hpp"

using namespace scheme;

namespace {
std::string read_write(const std::string& src) {
  SymbolTable syms;
  Reader r(src, syms);
  auto v = r.read();
  return v ? write_string(*v) : "<eof>";
}
}  // namespace

TEST(Reader, Atoms) {
  EXPECT_EQ(read_write("42"), "42");
  EXPECT_EQ(read_write("-7"), "-7");
  EXPECT_EQ(read_write("+5"), "5");
  EXPECT_EQ(read_write("-0"), "0");
  EXPECT_EQ(read_write("007"), "7");
  EXPECT_EQ(read_write("123456789012345678901234567890"), "123456789012345678901234567890");
  EXPECT_EQ(read_write("#t"), "#t");
  EXPECT_EQ(read_write("#f"), "#f");
}

TEST(Reader, SymbolsThatLookLikeNumbers) {
  SymbolTable syms;
  for (const char* s : {"+", "-", "...", "1+", "a.b", "list->string", "<=", "-x"}) {
    Reader r(s, syms);
    auto v = r.read();
    ASSERT_TRUE(v && v->is_symbol()) << s;
    EXPECT_EQ(v->as<Symbol>()->name, s);
  }
}

TEST(Reader, SymbolsAreInternedAndCaseSensitive) {
  SymbolTable syms;
  EXPECT_EQ(syms.intern("foo"), syms.intern("foo"));
  EXPECT_NE(syms.intern("Foo"), syms.intern("foo"));
}

TEST(Reader, ListsAndDots) {
  EXPECT_EQ(read_write("()"), "()");
  EXPECT_EQ(read_write("(1 2 3)"), "(1 2 3)");
  EXPECT_EQ(read_write("(1 . 2)"), "(1 . 2)");
  EXPECT_EQ(read_write("(1 2 . 3)"), "(1 2 . 3)");
  EXPECT_EQ(read_write("((1 2) (3 . 4) ())"), "((1 2) (3 . 4) ())");
}

TEST(Reader, QuoteShorthand) {
  EXPECT_EQ(read_write("'a"), "(quote a)");
  EXPECT_EQ(read_write("''a"), "(quote (quote a))");
  EXPECT_EQ(read_write("'(1 . 2)"), "(quote (1 . 2))");
}

TEST(Reader, StringsAndEscapes) {
  EXPECT_EQ(read_write("\"a\\\"b\\\\c\\nd\\te\""), "\"a\\\"b\\\\c\\nd\\te\"");
  EXPECT_EQ(read_write("\"raw\nlf\""), "\"raw\\nlf\"");
}

TEST(Reader, CommentsAndWhitespace) {
  EXPECT_EQ(read_write("  ; comment\n\t(a ; inner\n b)\r\n"), "(a b)");
  EXPECT_EQ(read_write("; only a comment"), "<eof>");
  EXPECT_EQ(read_write(""), "<eof>");
}

TEST(Reader, SequenceOfForms) {
  SymbolTable syms;
  Reader r("1 (2) foo", syms);
  EXPECT_EQ(write_string(*r.read()), "1");
  EXPECT_EQ(write_string(*r.read()), "(2)");
  EXPECT_EQ(write_string(*r.read()), "foo");
  EXPECT_FALSE(r.read().has_value());
}

TEST(Reader, MalformedInputThrows) {
  SymbolTable syms;
  Reader a("(1 2", syms);
  EXPECT_THROW(a.read(), SchemeError);
  Reader b("\"open", syms);
  EXPECT_THROW(b.read(), SchemeError);
  Reader c(")", syms);
  EXPECT_THROW(c.read(), SchemeError);
}
