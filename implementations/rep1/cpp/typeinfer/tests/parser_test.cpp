#include <gtest/gtest.h>

#include "typeinfer/errors.hpp"
#include "typeinfer/parser.hpp"

using namespace typeinfer;

namespace {

struct Fixture {
    SymbolTable symbols;
    Arena arena;
    std::vector<Token> tokens;
    std::string src;

    Decl parse_one(std::string s) {
        src = std::move(s);
        tokens = tokenize(src);
        Parser p(tokens, symbols, arena);
        auto d = p.next_declaration();
        EXPECT_TRUE(d.has_value());
        return *d;
    }
};

}  // namespace

TEST(Parser, EmptyProgramHasNoDeclarations) {
    SymbolTable symbols;
    Arena arena;
    auto toks = tokenize("  \n ");
    Parser p(toks, symbols, arena);
    EXPECT_FALSE(p.next_declaration().has_value());
}

TEST(Parser, LetWithParameters) {
    Fixture f;
    Decl d = f.parse_one("let f x y = x;;");
    EXPECT_EQ(d.kind, DeclKind::Let);
    EXPECT_EQ(f.symbols.name(d.name), "f");
    ASSERT_EQ(d.params.size(), 2u);
    EXPECT_EQ(d.body->kind, ExprKind::Var);
}

TEST(Parser, LetRec) {
    Fixture f;
    Decl d = f.parse_one("let rec f x = f x;;");
    EXPECT_EQ(d.kind, DeclKind::LetRec);
    EXPECT_EQ(d.body->kind, ExprKind::App);
}

TEST(Parser, PrecedenceOfArithmeticAndApplication) {
    Fixture f;
    // f x + g y * 2  ==  (f x) + ((g y) * 2)
    Decl d = f.parse_one("f x + g y * 2;;");
    const Expr* e = d.body;
    ASSERT_EQ(e->kind, ExprKind::Binary);
    EXPECT_EQ(e->op, BinaryOp::Add);
    EXPECT_EQ(e->first->kind, ExprKind::App);
    ASSERT_EQ(e->second->kind, ExprKind::Binary);
    EXPECT_EQ(e->second->op, BinaryOp::Mul);
}

TEST(Parser, ConsIsRightAssociative) {
    Fixture f;
    Decl d = f.parse_one("1 :: 2 :: [];;");
    ASSERT_EQ(d.body->kind, ExprKind::Cons);
    EXPECT_EQ(d.body->second->kind, ExprKind::Cons);
}

TEST(Parser, SubtractionIsLeftAssociative) {
    Fixture f;
    Decl d = f.parse_one("1 - 2 - 3;;");
    ASSERT_EQ(d.body->kind, ExprKind::Binary);
    EXPECT_EQ(d.body->first->kind, ExprKind::Binary);
    EXPECT_EQ(d.body->second->kind, ExprKind::Int);
}

TEST(Parser, ComparisonBindsLooserThanArithmeticTighterThanAnd) {
    Fixture f;
    Decl d = f.parse_one("a < b + 1 && c;;");
    ASSERT_EQ(d.body->kind, ExprKind::Binary);
    EXPECT_EQ(d.body->op, BinaryOp::And);
    EXPECT_EQ(d.body->first->op, BinaryOp::Lt);
}

TEST(Parser, FunBodyStopsAtComma) {
    Fixture f;
    Decl d = f.parse_one("(fun x -> x, 1);;");
    ASSERT_EQ(d.body->kind, ExprKind::Tuple);
    EXPECT_EQ(d.body->items.size(), 2u);
    EXPECT_EQ(d.body->items[0]->kind, ExprKind::Lambda);
}

TEST(Parser, TupleVersusParenthesised) {
    Fixture f;
    EXPECT_EQ(f.parse_one("(1);;").body->kind, ExprKind::Int);
    EXPECT_EQ(f.parse_one("();;").body->kind, ExprKind::Unit);
    Decl d = f.parse_one("(1, 2, 3);;");
    ASSERT_EQ(d.body->kind, ExprKind::Tuple);
    EXPECT_EQ(d.body->items.size(), 3u);
}

TEST(Parser, ListLiterals) {
    Fixture f;
    EXPECT_EQ(f.parse_one("[];;").body->kind, ExprKind::Nil);
    Decl d = f.parse_one("[1; 2; 3];;");
    ASSERT_EQ(d.body->kind, ExprKind::List);
    EXPECT_EQ(d.body->items.size(), 3u);
}

TEST(Parser, ApplicationIsNary) {
    Fixture f;
    Decl d = f.parse_one("f 1 2 3;;");
    ASSERT_EQ(d.body->kind, ExprKind::App);
    EXPECT_EQ(d.body->items.size(), 3u);
}

TEST(Parser, ElseBranchExtendsRight) {
    Fixture f;
    Decl d = f.parse_one("if a then b else c + 1;;");
    ASSERT_EQ(d.body->kind, ExprKind::If);
    EXPECT_EQ(d.body->third->kind, ExprKind::Binary);
}

TEST(Parser, LetExpressionInParentheses) {
    Fixture f;
    Decl d = f.parse_one("(let x = 1 in x);;");
    EXPECT_EQ(d.kind, DeclKind::Expr);
    EXPECT_EQ(d.body->kind, ExprKind::Let);
}

TEST(Parser, ParsesDeclarationsOneAtATime) {
    SymbolTable symbols;
    Arena arena;
    auto toks = tokenize("1;;2;;");
    Parser p(toks, symbols, arena);
    EXPECT_TRUE(p.next_declaration());
    EXPECT_TRUE(p.next_declaration());
    EXPECT_FALSE(p.next_declaration());
}

TEST(Parser, MalformedInputThrows) {
    SymbolTable symbols;
    Arena arena;
    auto toks = tokenize("let = 1;;");
    Parser p(toks, symbols, arena);
    EXPECT_THROW(p.next_declaration(), ParseError);
}
