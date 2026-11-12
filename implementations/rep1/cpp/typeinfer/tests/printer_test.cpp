#include <gtest/gtest.h>

#include "typeinfer/printer.hpp"

using namespace typeinfer;

namespace {
struct P : ::testing::Test {
    TypeStore s;
    Type* I() { return s.int_type(); }
    Type* B() { return s.bool_type(); }
    Type* pair(Type* a, Type* b) {
        Type* ts[] = {a, b};
        return s.tuple(ts);
    }
    std::string str(Type* t) { return print_type(s, t); }
};
}  // namespace

TEST_F(P, BaseTypes) {
    EXPECT_EQ(str(I()), "int");
    EXPECT_EQ(str(B()), "bool");
    EXPECT_EQ(str(s.unit_type()), "unit");
}

TEST_F(P, VariablesNamedByFirstAppearance) {
    Type* a = s.fresh_var(1);
    Type* b = s.fresh_var(1);
    EXPECT_EQ(str(s.fun(b, s.fun(a, b))), "'a -> 'b -> 'a");
}

TEST_F(P, VariableNamesWrapAfterZ) {
    std::vector<Type*> vs;
    for (int i = 0; i < 60; ++i) vs.push_back(s.fresh_var(1));
    Type* t = s.tuple(vs);
    std::string out = str(t);
    EXPECT_NE(out.find("'z * 'a1 * 'b1"), std::string::npos);
    EXPECT_NE(out.find("'a2"), std::string::npos);
    EXPECT_NE(out.find("'h2"), std::string::npos);  // index 59
}

TEST_F(P, ArrowIsRightAssociative) {
    Type* t = s.fun(I(), s.fun(I(), I()));
    EXPECT_EQ(str(t), "int -> int -> int");
    EXPECT_EQ(str(s.fun(s.fun(I(), I()), I())), "(int -> int) -> int");
}

TEST_F(P, TuplesAndArrows) {
    EXPECT_EQ(str(s.fun(pair(I(), B()), pair(B(), I()))), "int * bool -> bool * int");
    EXPECT_EQ(str(pair(s.fun(I(), I()), pair(I(), I()))), "(int -> int) * (int * int)");
}

TEST_F(P, NestedPairIsNotAThreeTuple) {
    Type* three[] = {I(), I(), I()};
    EXPECT_EQ(str(s.tuple(three)), "int * int * int");
    EXPECT_EQ(str(pair(pair(I(), I()), I())), "(int * int) * int");
}

TEST_F(P, ListsArePostfix) {
    EXPECT_EQ(str(s.list(s.list(I()))), "int list list");
    EXPECT_EQ(str(s.list(s.fun(I(), I()))), "(int -> int) list");
    EXPECT_EQ(str(s.list(pair(I(), B()))), "(int * bool) list");
    EXPECT_EQ(str(s.fun(s.list(I()), s.list(B()))), "int list -> bool list");
}

TEST_F(P, NamesAreLocalToEachCall) {
    Type* v = s.fresh_var(1);
    Type* w = s.fresh_var(1);
    EXPECT_EQ(str(s.fun(v, w)), "'a -> 'b");
    EXPECT_EQ(str(s.fun(w, v)), "'a -> 'b");
}
