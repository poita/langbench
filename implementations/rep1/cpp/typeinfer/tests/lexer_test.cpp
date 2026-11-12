#include <gtest/gtest.h>

#include "typeinfer/errors.hpp"
#include "typeinfer/lexer.hpp"

using namespace typeinfer;

namespace {
std::vector<TokenKind> kinds(std::string_view src) {
    std::vector<TokenKind> out;
    for (const Token& t : tokenize(src)) out.push_back(t.kind);
    return out;
}
}  // namespace

TEST(Lexer, EmptyInputYieldsOnlyEnd) {
    EXPECT_EQ(kinds(""), std::vector<TokenKind>{TokenKind::End});
    EXPECT_EQ(kinds(" \t\r\n "), std::vector<TokenKind>{TokenKind::End});
}

TEST(Lexer, KeywordsAndIdentifiers) {
    auto ks = kinds("let rec in fun if then else true false letx funny inx x_1 aB");
    std::vector<TokenKind> want = {
        TokenKind::KwLet, TokenKind::KwRec, TokenKind::KwIn,  TokenKind::KwFun,
        TokenKind::KwIf,  TokenKind::KwThen, TokenKind::KwElse, TokenKind::KwTrue,
        TokenKind::KwFalse, TokenKind::Ident, TokenKind::Ident, TokenKind::Ident,
        TokenKind::Ident, TokenKind::Ident, TokenKind::End};
    EXPECT_EQ(ks, want);
}

TEST(Lexer, LongestMatchSymbols) {
    auto ks = kinds(";;->::<=>=&&||;,< =");
    std::vector<TokenKind> want = {
        TokenKind::SemiSemi, TokenKind::Arrow, TokenKind::ColonColon, TokenKind::Le,
        TokenKind::Ge, TokenKind::AndAnd, TokenKind::OrOr, TokenKind::Semi,
        TokenKind::Comma, TokenKind::Lt, TokenKind::Eq, TokenKind::End};
    EXPECT_EQ(ks, want);
}

TEST(Lexer, BigIntegerIsOneToken) {
    auto toks = tokenize("123456789012345678901234567890");
    ASSERT_EQ(toks.size(), 2u);
    EXPECT_EQ(toks[0].kind, TokenKind::Int);
    EXPECT_EQ(toks[0].text, "123456789012345678901234567890");
}

TEST(Lexer, RecordsOffsets) {
    auto toks = tokenize("a  bc");
    EXPECT_EQ(toks[0].offset, 0u);
    EXPECT_EQ(toks[1].offset, 3u);
}

TEST(Lexer, RejectsUnknownCharacter) {
    EXPECT_THROW(tokenize("a $ b"), ParseError);
    EXPECT_THROW(tokenize("a | b"), ParseError);
}
