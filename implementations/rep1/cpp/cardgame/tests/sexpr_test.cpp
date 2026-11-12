#include <gtest/gtest.h>

#include "spiremark/sexpr.hpp"

using spiremark::DatabaseError;
using spiremark::Sexpr;
using spiremark::parse_sexprs;

TEST(Sexpr, ParsesAtomsStringsAndLists) {
    auto forms = parse_sexprs("(card X-1 \"a b\" -12 (nested))");
    ASSERT_EQ(forms.size(), 1u);
    const Sexpr& f = forms[0];
    ASSERT_TRUE(f.is_list());
    ASSERT_EQ(f.items.size(), 5u);
    EXPECT_TRUE(f.items[0].is_symbol());
    EXPECT_TRUE(f.items[2].is_string());
    EXPECT_EQ(f.items[2].text, "a b");
    EXPECT_TRUE(f.items[3].is_int());
    EXPECT_EQ(f.items[3].value, -12);
    EXPECT_TRUE(f.items[4].is_list());
}

TEST(Sexpr, SkipsCommentsAndAllWhitespaceKinds) {
    auto forms = parse_sexprs("; head\n(a\t\r\f\v b) ; tail\n");
    ASSERT_EQ(forms.size(), 1u);
    EXPECT_EQ(forms[0].items.size(), 2u);
}

TEST(Sexpr, SemicolonInsideStringIsNotAComment) {
    auto forms = parse_sexprs("(\"x;y\")");
    ASSERT_EQ(forms.size(), 1u);
    EXPECT_EQ(forms[0].items[0].text, "x;y");
}

TEST(Sexpr, IntegerAtomRules) {
    auto forms = parse_sexprs("(-0 007 - +5 1a)");
    ASSERT_EQ(forms.size(), 1u);
    const auto& it = forms[0].items;
    EXPECT_TRUE(it[0].is_int());
    EXPECT_TRUE(it[1].is_int());
    EXPECT_EQ(it[1].value, 7);
    EXPECT_TRUE(it[2].is_symbol());
    EXPECT_TRUE(it[3].is_symbol());
    EXPECT_TRUE(it[4].is_symbol());
}

TEST(Sexpr, Int64Limits) {
    EXPECT_NO_THROW(parse_sexprs("(9223372036854775807 -9223372036854775808)"));
    EXPECT_THROW(parse_sexprs("(9223372036854775808)"), DatabaseError);
}

TEST(Sexpr, RejectsMalformedInput) {
    EXPECT_THROW(parse_sexprs("(a b"), DatabaseError);
    EXPECT_THROW(parse_sexprs("(a))"), DatabaseError);
    EXPECT_THROW(parse_sexprs("(\"open)"), DatabaseError);
    EXPECT_THROW(parse_sexprs("(\"new\nline\")"), DatabaseError);
}

TEST(Sexpr, PrintsCanonically) {
    auto forms = parse_sexprs("(  damage   2 (t   1) \"s\" 007 )");
    EXPECT_EQ(forms[0].print(), "(damage 2 (t 1) \"s\" 7)");
}
